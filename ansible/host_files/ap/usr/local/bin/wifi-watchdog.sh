#!/bin/bash
# 6GHz AP (rtw89) のFWデータパス詰まり検知 → ドライバリロードで自動復旧
# 署名: 直近90秒で6GHzのinactivity deauthが2件以上 (wedge時は全クライアントが同時にdeauthされる)
#      かつ、その後クライアントが1台も戻ってきていない (= 単なる離席との区別)
IFACE=wlxccbabd331008
STAMP=/run/wifi-watchdog.last-reload
COOLDOWN=600   # 直近この秒数内にリロード済みなら何もしない

recent=$(journalctl -u hostapd --since "-90 seconds" -q --no-pager 2>/dev/null \
  | grep "$IFACE" | grep -c "deauthenticated due to inactivity")

[ "$recent" -ge 2 ] || exit 0

# wedgeなら誰も再接続できていないはず。1台でも繋がっているなら通常の離席なので何もしない
stations=$(iw dev "$IFACE" station dump 2>/dev/null | grep -c '^Station')
if [ "$stations" -gt 0 ]; then
    logger -t wifi-watchdog "deauth burst (${recent}) but ${stations} station(s) still associated - not a wedge, skipping"
    exit 0
fi

# 連続リロードで延々とAPを落とさないためのクールダウン
if [ -f "$STAMP" ]; then
    age=$(( $(date +%s) - $(stat -c %Y "$STAMP") ))
    if [ "$age" -lt "$COOLDOWN" ]; then
        logger -t wifi-watchdog "wedge signature seen but reloaded ${age}s ago (cooldown ${COOLDOWN}s) - skipping"
        exit 0
    fi
fi

logger -t wifi-watchdog "6GHz wedge detected (${recent} inactivity deauths in 90s, 0 stations) - reloading rtw89"
touch "$STAMP"

systemctl stop hostapd

# 依存順に明示的に外す。rtw89_8852cu_git だけでは 8852c/usb/core が残り core の削除が失敗する
modprobe -r rtw89_8852cu_git rtw89_8852c_git rtw89_usb_git rtw89_core_git
sleep 2
if lsmod | grep -q '^rtw89_core_git'; then
    logger -t wifi-watchdog "WARNING: rtw89_core_git still loaded after rmmod - reload may not take effect"
fi

modprobe rtw89_8852cu_git || logger -t wifi-watchdog "ERROR: modprobe rtw89_8852cu_git failed"

# USB再列挙とインターフェース出現を待つ (最大15秒)
for _ in $(seq 15); do
    [ -e "/sys/class/net/${IFACE}" ] && break
    sleep 1
done
if [ ! -e "/sys/class/net/${IFACE}" ]; then
    logger -t wifi-watchdog "ERROR: ${IFACE} did not reappear after driver reload"
fi

systemctl start hostapd
sleep 5
if [ "$(cat "/sys/class/net/${IFACE}/operstate" 2>/dev/null)" != "down" ] \
   && iw dev "$IFACE" info 2>/dev/null | grep -q 'type AP'; then
    logger -t wifi-watchdog "rtw89 reload complete, 6GHz AP back up"
else
    logger -t wifi-watchdog "ERROR: 6GHz AP did not come back up after reload"
fi
