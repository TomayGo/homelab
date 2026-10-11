#!/bin/bash

printf "HTTP/1.1 200 OK\r\n"
printf "Content-Type: text/plain; version=0.0.4\r\n"
printf "\r\n"

IFACES="wlp6s16:2.4GHz wlxd056f28908dc:5GHz wlxccbabd331008:6GHz"

# --- 端末の名前とベンダー (2026-10-12追加) ---
# 名前は ansible が host_vars/ap/wifi_devices.sops.yaml から作る。OUI 一覧は wifi-oui-update.timer が週 1 回取ってくる
DEVICES_FILE=/etc/wifi-exporter/devices.tsv
OUI_FILE=/var/lib/wifi-exporter/manuf
OUI_FALLBACK=/usr/share/ieee-data/oui.txt
VENDOR_CACHE=/run/wifi-exporter/vendor.tsv

# ラベル値に入れられない文字 (" \ 改行) を落とす
sanitize() { tr -d '"\\\n'; }

# "Samsung Electronics Co.,Ltd" -> "Samsung Electronics"
shorten() {
    sed -E 's/,.*//; s/ +$//' | sed -E 's/ (Inc\.?|Corporation|Corporate|Corp\.?|Co\.?|Ltd\.?|LLC|GmbH)$//I; s/ (Inc\.?|Co\.?|Ltd\.?)$//I'
}

name_of() {
    awk -F'\t' -v m="$1" '!/^#/ && tolower($1) == m { print $2; exit }' "$DEVICES_FILE" 2>/dev/null
}

vendor_of() {
    local mac=$1 hex v
    # ローカル管理ビットが立っている = スマホなどのプライベート (ランダム) アドレス。OUI は意味を持たない
    if (( 0x${mac:0:2} & 2 )); then echo "ランダム MAC"; return; fi
    v=$(awk -F'\t' -v m="$mac" '$1 == m { print $2; exit }' "$VENDOR_CACHE" 2>/dev/null)
    if [ -n "$v" ]; then echo "$v"; return; fi
    hex=$(echo "${mac^^}" | tr -d :)
    if [ -r "$OUI_FILE" ]; then
        # 24/28/36 ビットのブロックのうち、いちばん長く一致するもの
        v=$(grep -i "^${mac:0:8}" "$OUI_FILE" | awk -F'\t' -v hex="$hex" '{
                split($1, a, "/"); gsub(/[ :]/, "", a[1]); bits = (a[2] == "" ? 24 : a[2]); n = bits / 4
                if (substr(hex, 1, n) == substr(toupper(a[1]), 1, n) && bits > best) { best = bits; v = $3 }
            } END { print v }' | shorten)
        if [ -n "$v" ]; then
            mkdir -p "${VENDOR_CACHE%/*}" && printf '%s\t%s\n' "$mac" "$v" >> "$VENDOR_CACHE"
        fi
    elif [ -r "$OUI_FALLBACK" ]; then
        v=$(grep -m1 "^${hex:0:6}" "$OUI_FALLBACK" | cut -f3 | shorten)
    fi
    echo "${v:-不明}"
}

# --- AP自体の生死 (2026-07-28追加: hostapd死亡を検知できずアラートが上がらなかったため) ---
echo "# HELP hostapd_up hostapd process is running (1) or not (0)"
echo "# TYPE hostapd_up gauge"
if pidof hostapd >/dev/null 2>&1; then
    echo "hostapd_up 1"
else
    echo "hostapd_up 0"
fi

echo "# HELP hostapd_interface_up AP interface is up and in AP mode (1) or not (0)"
echo "# TYPE hostapd_interface_up gauge"
for entry in $IFACES; do
    iface="${entry%%:*}"; band="${entry#*:}"
    state=$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null)
    iftype=$(iw dev "$iface" info 2>/dev/null | awk '$1=="type"{print $2}')
    if [ -n "$state" ] && [ "$state" != "down" ] && [ "$iftype" = "AP" ]; then
        echo "hostapd_interface_up{interface=\"${iface}\", band=\"${band}\"} 1"
    else
        echo "hostapd_interface_up{interface=\"${iface}\", band=\"${band}\"} 0"
    fi
done

echo "# HELP hostapd_clients_total Total connected clients"
echo "# TYPE hostapd_clients_total gauge"
for entry in $IFACES; do
    iface="${entry%%:*}"; band="${entry#*:}"
    count=$(sudo hostapd_cli -p /var/run/hostapd -i "$iface" all_sta 2>/dev/null | grep -c "dot11RSNAStatsSTAAddress")
    echo "hostapd_clients_total{interface=\"${iface}\", band=\"${band}\"} ${count:-0}"
done

echo "# HELP hostapd_client_rx_bytes_total Bytes received from client"
echo "# TYPE hostapd_client_rx_bytes_total counter"
echo "# HELP hostapd_client_tx_bytes_total Bytes transmitted to client"
echo "# TYPE hostapd_client_tx_bytes_total counter"
echo "# HELP hostapd_client_signal_dbm Client signal strength in dBm"
echo "# TYPE hostapd_client_signal_dbm gauge"
echo "# HELP hostapd_client_tx_bitrate_mbps Client TX bitrate in Mbps"
echo "# TYPE hostapd_client_tx_bitrate_mbps gauge"

info_lines=""
for entry in $IFACES; do
    iface="${entry%%:*}"; band="${entry#*:}"
    dump=$(sudo iw dev "$iface" station dump 2>/dev/null)
    echo "$dump" | awk -v iface="$iface" '
        /^Station/ { mac=$2 }
        /rx bytes:/ { print "hostapd_client_rx_bytes_total{interface=\"" iface "\", mac=\"" mac "\"}", $3 }
        /tx bytes:/ { print "hostapd_client_tx_bytes_total{interface=\"" iface "\", mac=\"" mac "\"}", $3 }
        /signal:/ && $2 ~ /^-?[0-9]+(\.[0-9]+)?$/ { print "hostapd_client_signal_dbm{interface=\"" iface "\", mac=\"" mac "\"}", $2 }
        /tx bitrate:/ && $3 ~ /^[0-9]+(\.[0-9]+)?$/ { print "hostapd_client_tx_bitrate_mbps{interface=\"" iface "\", mac=\"" mac "\"}", $3 }
    '
    for mac in $(echo "$dump" | awk '/^Station/ { print $2 }'); do
        vendor=$(vendor_of "$mac" | sanitize)
        name=$(name_of "$mac" | sanitize)
        device=${name:-"${vendor} (${mac:12:5})"}
        info_lines+="hostapd_client_info{interface=\"${iface}\", band=\"${band}\", mac=\"${mac}\", vendor=\"${vendor}\", name=\"${name}\", device=\"${device}\"} 1"$'\n'
    done
done

echo "# HELP hostapd_client_info Connected client. name = /etc/wifi-exporter/devices.tsv, vendor = OUI lookup, device = name or vendor + last 2 octets"
echo "# TYPE hostapd_client_info gauge"
printf '%s' "$info_lines"

flush_timeouts=$(journalctl -k -b -q -o cat --no-pager -g "timed out to flush queues" 2>/dev/null | grep -c .)
echo "# HELP wifi_flush_queue_timeouts_total Kernel 'timed out to flush queues' events since boot"
echo "# TYPE wifi_flush_queue_timeouts_total counter"
echo "wifi_flush_queue_timeouts_total{driver=\"rtw89_8852cu_git\"} ${flush_timeouts:-0}"
