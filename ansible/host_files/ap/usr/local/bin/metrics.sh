#!/bin/bash

printf "HTTP/1.1 200 OK\r\n"
printf "Content-Type: text/plain; version=0.0.4\r\n"
printf "\r\n"

IFACES="wlp6s16:2.4GHz wlxd056f28908dc:5GHz wlxccbabd331008:6GHz"

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

for entry in $IFACES; do
    iface="${entry%%:*}"
    sudo iw dev "$iface" station dump 2>/dev/null | awk -v iface="$iface" '
        /^Station/ { mac=$2 }
        /rx bytes:/ { print "hostapd_client_rx_bytes_total{interface=\"" iface "\", mac=\"" mac "\"}", $3 }
        /tx bytes:/ { print "hostapd_client_tx_bytes_total{interface=\"" iface "\", mac=\"" mac "\"}", $3 }
        /signal:/ && $2 ~ /^-?[0-9]+(\.[0-9]+)?$/ { print "hostapd_client_signal_dbm{interface=\"" iface "\", mac=\"" mac "\"}", $2 }
        /tx bitrate:/ && $3 ~ /^[0-9]+(\.[0-9]+)?$/ { print "hostapd_client_tx_bitrate_mbps{interface=\"" iface "\", mac=\"" mac "\"}", $3 }
    '
done

flush_timeouts=$(journalctl -k -b -q -o cat --no-pager -g "timed out to flush queues" 2>/dev/null | grep -c .)
echo "# HELP wifi_flush_queue_timeouts_total Kernel 'timed out to flush queues' events since boot"
echo "# TYPE wifi_flush_queue_timeouts_total counter"
echo "wifi_flush_queue_timeouts_total{driver=\"rtw89_8852cu_git\"} ${flush_timeouts:-0}"
