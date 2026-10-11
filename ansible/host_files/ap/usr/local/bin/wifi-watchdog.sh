#!/bin/bash
# Wi-Fi APのドライバ詰まりを検知して、ドライバリロードで自動復旧する（2分ごとにtimerから実行）
#
# 6GHz (rtw89) のFWデータパス詰まり
#   署名: 直近90秒で6GHzのinactivity deauthが2件以上 (wedge時は全クライアントが同時にdeauthされる)
#        かつ、その後クライアントが1台も戻ってきていない (= 単なる離席との区別)
#
# 5GHz (rtw88) の送信停止 (2026-09-29, 2026-09-30〜10-11に発生)
#   ビーコンは出続けるので端末からは見えるが、認証応答・EAPOLが電波に出ず誰も接続できない
#   署名: 直近15分で5GHzの鍵交換成功が0件、かつ接続の試み (authenticated / associated /
#        inactivity deauth) が3件以上。直近30分に鍵交換が成功した端末の試みは数えない
#        (別バンドへ移っただけのprune)。パスワード違いの1台を拾わないよう、試みた端末が
#        2台以上か、rtw88の "failed to get tx report" が3件以上あることも条件にする
#   9/28〜10/11のログで、本物の停止2件だけで発動することを確認した
IF6=wlxccbabd331008
IF5=wlxd056f28908dc
STAMP6=/run/wifi-watchdog.last-reload        # 6GHz (旧来のファイル名のまま)
STAMP5=/run/wifi-watchdog.last-reload-5g
COOLDOWN6=600    # 直近この秒数内にリロード済みなら何もしない
COOLDOWN5=1800
WINDOW5=900
RECENT5=1800
DUMPDIR=/var/log/wifi-watchdog

# $1=STAMP $2=COOLDOWN $3=名前。クールダウン中なら1を返す
cooled_down() {
    [ -f "$1" ] || return 0
    local age=$(( $(date +%s) - $(stat -c %Y "$1") ))
    if [ "$age" -lt "$2" ]; then
        logger -t wifi-watchdog "$3 signature seen but reloaded ${age}s ago (cooldown $2s) - skipping"
        return 1
    fi
}

# $1=IF $2=名前 $3..=外す順のモジュール（先頭を読み込み直す）
reload_driver() {
    local iface=$1 name=$2; shift 2
    systemctl stop hostapd

    # 依存順に明示的に外す。先頭だけ外しても core などが残り、読み直しにならない
    modprobe -r "$@"
    sleep 2
    if lsmod | grep -q "^${!#} "; then
        logger -t wifi-watchdog "WARNING: ${!#} still loaded after rmmod - reload may not take effect"
    fi
    modprobe "$1" || logger -t wifi-watchdog "ERROR: modprobe $1 failed"

    # USB再列挙とインターフェース出現を待つ (最大15秒)
    for _ in $(seq 15); do
        [ -e "/sys/class/net/${iface}" ] && break
        sleep 1
    done
    if [ ! -e "/sys/class/net/${iface}" ]; then
        logger -t wifi-watchdog "ERROR: ${iface} did not reappear after driver reload"
    fi

    systemctl start hostapd
    sleep 5
    if [ "$(cat "/sys/class/net/${iface}/operstate" 2>/dev/null)" != "down" ] \
       && iw dev "$iface" info 2>/dev/null | grep -q 'type AP'; then
        logger -t wifi-watchdog "$1 reload complete, ${name} AP back up (usb $(cat /sys/class/net/${iface}/device/../speed 2>/dev/null)M)"
    else
        logger -t wifi-watchdog "ERROR: ${name} AP did not come back up after reload"
    fi
}

# 5GHz: 読み直す前にチップの状態を残す（原因が未特定のため。2026-10-11の記録ではFIFO空・TXPAUSE 0・EDCCA正常）
dump_5g() {
    local dbg out
    dbg=/sys/kernel/debug/ieee80211/$(basename "$(readlink -f /sys/class/net/$IF5/phy80211)")/rtw88
    mkdir -p "$DUMPDIR"
    out=$DUMPDIR/5g-$(date +%Y%m%d-%H%M%S).log
    {
        echo "### $(date -Is) $(uname -r) usb=$(cat /sys/class/net/$IF5/device/../speed)M"
        echo "$1"
        for r in 210 230 234 238 23c 240 418 520 8a0 8a4 2d38; do
            echo "$r 4" > "$dbg/read_reg" && echo "$r $(grep -o '0x[0-9a-f]*$' "$dbg/read_reg")"
        done
        echo "edcca_enable=$(cat $dbg/edcca_enable 2>/dev/null)"
        for f in mac_0 mac_2 mac_4 mac_5; do echo "--- $f"; cat "$dbg/$f"; done
        echo "--- phy_info"; cat "$dbg/phy_info"
        echo "--- station dump"; iw dev $IF5 station dump
        echo "--- ip -s link"; ip -s link show $IF5
        echo "--- hostapd (${WINDOW5}s)"; journalctl -u hostapd --since "-${WINDOW5} seconds" -q --no-pager | grep "$IF5"
    } > "$out" 2>&1
    ls -1t "$DUMPDIR"/5g-*.log | tail -n +21 | xargs -r rm -f
    echo "$out"
}

check_6g() {
    local recent stations
    recent=$(journalctl -u hostapd --since "-90 seconds" -q --no-pager 2>/dev/null \
      | grep "$IF6" | grep -c "deauthenticated due to inactivity")
    [ "$recent" -ge 2 ] || return 0

    # wedgeなら誰も再接続できていないはず。1台でも繋がっているなら通常の離席なので何もしない
    stations=$(iw dev "$IF6" station dump 2>/dev/null | grep -c '^Station')
    if [ "$stations" -gt 0 ]; then
        logger -t wifi-watchdog "deauth burst (${recent}) but ${stations} station(s) still associated - not a wedge, skipping"
        return 0
    fi
    cooled_down "$STAMP6" "$COOLDOWN6" "6GHz wedge" || return 0

    logger -t wifi-watchdog "6GHz wedge detected (${recent} inactivity deauths in 90s, 0 stations) - reloading rtw89"
    touch "$STAMP6"
    reload_driver "$IF6" 6GHz rtw89_8852cu_git rtw89_8852c_git rtw89_usb_git rtw89_core_git
}

check_5g() {
    local stats hs att nsta txfail summary dump
    [ -e "/sys/class/net/$IF5" ] || return 0

    # 出力: 窓内の鍵交換成功数 / 数える試み / 試みた端末数
    stats=$(journalctl -u hostapd --since "-${RECENT5} seconds" -o short-unix -q --no-pager 2>/dev/null \
      | grep " $IF5: STA " \
      | awk -v from=$(( $(date +%s) - WINDOW5 )) '
          { sta = ""; for (i = 1; i <= NF; i++) if ($i == "STA") sta = $(i + 1) }
          /handshake completed/ { ok[sta] = 1; if ($1 >= from) hs++; next }
          /IEEE 802.11: (associated|authenticated|deauthenticated due to inactivity)/ {
              if ($1 >= from) { n++; t[n] = sta } }
          END {
              for (i = 1; i <= n; i++) if (!(t[i] in ok)) { c++; s[t[i]] = 1 }
              for (k in s) d++
              print hs + 0, c + 0, d + 0 }')
    read -r hs att nsta <<< "$stats"
    [ "$hs" -eq 0 ] && [ "$att" -ge 3 ] || return 0

    txfail=$(journalctl -k --since "-${WINDOW5} seconds" -q --no-pager 2>/dev/null \
      | grep rtw88_8822bu | grep -c 'failed to get tx report')
    summary="${att} attempts from ${nsta} station(s), 0 handshakes, ${txfail} tx report failures in ${WINDOW5}s"
    if [ "$nsta" -lt 2 ] && [ "$txfail" -lt 3 ]; then
        logger -t wifi-watchdog "5GHz: ${summary} - single station without tx report failures (wrong password?), skipping"
        return 0
    fi
    cooled_down "$STAMP5" "$COOLDOWN5" "5GHz tx stall" || return 0

    dump=$(dump_5g "$summary")
    logger -t wifi-watchdog "5GHz tx stall detected (${summary}) - state saved to ${dump}, reloading rtw88"
    touch "$STAMP5"
    reload_driver "$IF5" 5GHz rtw88_8822bu rtw88_8822b rtw88_usb rtw88_core
}

check_6g
check_5g
