#!/bin/bash
# Thunderbolt コントローラ (NHI) が wedge したときのイベントストームを検知して、その domain の
# ドライバを unbind する。
#
# 2026-10-23 (pve-3) と 2026-10-27 (pve-1) に、リンクのフラップ後に NHI が固まり、router 0 の
# ポートから TB_CFG_PKG_EVENT が ~100/s 出続けた。ドライバは毎回 ERROR を返し、そのたびに
# tb_ctl_pkg_alloc の確保がリークする (~2.5-4 GB/日)。unbind するとストームが止まり、
# リークした分も解放される (再起動は不要)。
#
# - 平常時のイベントは 0/s。SAMPLE_SEC 秒で THRESHOLD 件を超える状態が CONSECUTIVE 回続いたら unbind する
# - 自動で bind し直すことはしない。wedge した NHI への bind は -110 で失敗し、kworker が D 状態で
#   残って再起動しか手がなくなる (2026-10-30)。復旧はケーブル確認のうえ手動で再起動する
# - 1 ホストで unbind するのは 1 domain まで。もう片方が unbind 済みなら何もせずログだけ残す
#   (両方外すとそのホストがメッシュから切れる)
# - TB_WATCHDOG_DRY_RUN=1 で unbind せずに判定だけ行う
set -u

SAMPLE_SEC=${TB_WATCHDOG_SAMPLE_SEC:-5}
THRESHOLD=${TB_WATCHDOG_THRESHOLD:-50}
CONSECUTIVE=${TB_WATCHDOG_CONSECUTIVE:-2}
DRY_RUN=${TB_WATCHDOG_DRY_RUN:-0}
STATE_DIR=/run/tb-storm-watchdog
INST=/sys/kernel/tracing/instances/tb-storm-watchdog
DRV=/sys/bus/pci/drivers/thunderbolt

log() { echo "$1"; logger -t tb-storm-watchdog -p "daemon.${2:-notice}" -- "$1"; }

mkdir -p "$STATE_DIR"
# 他のトレース利用者とぶつからないように専用のインスタンスを使う
[ -d "$INST" ] || mkdir "$INST" || exit 1

echo > "$INST/trace"
echo 1 > "$INST/events/thunderbolt/tb_event/enable"
sleep "$SAMPLE_SEC"
echo 0 > "$INST/events/thunderbolt/tb_event/enable"
counts=$(grep -o 'domain=[0-9]*' "$INST/trace" | sort | uniq -c)
echo > "$INST/trace"

bound_domains() {
	for d in /sys/bus/thunderbolt/devices/domain*; do
		[ -e "$d" ] && basename "$d" | sed 's/^domain//'
	done
}

for dom in $(bound_domains); do
	n=$(awk -v d="domain=$dom" '$2 == d {print $1}' <<<"$counts")
	n=${n:-0}
	streak_file="$STATE_DIR/domain$dom"
	if [ "$n" -le "$THRESHOLD" ]; then
		rm -f "$streak_file"
		continue
	fi
	streak=$(( $(cat "$streak_file" 2>/dev/null || echo 0) + 1 ))
	echo "$streak" > "$streak_file"
	pci=$(basename "$(readlink -f "/sys/bus/thunderbolt/devices/domain$dom/..")")
	log "domain$dom ($pci): $n events in ${SAMPLE_SEC}s (streak $streak/$CONSECUTIVE)" warning
	[ "$streak" -lt "$CONSECUTIVE" ] && continue

	# もう片方の NHI が unbind 済み (ドライバなし) なら、このホストを孤立させないように止める
	# (NHI = PCI class 0x0c0340, USB4 host interface)
	others_unbound=0
	for f in /sys/bus/pci/devices/*; do
		[ "$(basename "$f")" = "$pci" ] && continue
		[ "$(cat "$f/class")" = 0x0c0340 ] || continue
		[ -e "$f/driver" ] || others_unbound=1
	done
	if [ "$others_unbound" = 1 ]; then
		log "domain$dom ($pci): event storm, but another NHI is already unbound; NOT unbinding (would isolate the host). Manual action needed." crit
		continue
	fi

	if [ "$DRY_RUN" = 1 ]; then
		log "domain$dom ($pci): DRY RUN, would unbind thunderbolt" warning
		continue
	fi
	log "domain$dom ($pci): unbinding thunderbolt to stop the event storm and free the leaked memory. Do NOT rebind; reboot the host after checking the cable." crit
	echo "$pci" > "$DRV/unbind"
	rm -f "$streak_file"
	log "domain$dom ($pci): unbind rc=$?" crit
done
