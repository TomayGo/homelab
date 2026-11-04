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
# - 判定の結果と NHI の bind 状態を node_exporter の textfile collector に書き出す。Discord への通知は
#   k8s/apps/kube-prometheus-stack/values.yaml の thunderbolt グループのアラートが行う
set -u

SAMPLE_SEC=${TB_WATCHDOG_SAMPLE_SEC:-5}
THRESHOLD=${TB_WATCHDOG_THRESHOLD:-50}
CONSECUTIVE=${TB_WATCHDOG_CONSECUTIVE:-2}
DRY_RUN=${TB_WATCHDOG_DRY_RUN:-0}
STATE_DIR=/run/tb-storm-watchdog
INST=/sys/kernel/tracing/instances/tb-storm-watchdog
DRV=/sys/bus/pci/drivers/thunderbolt
# node_exporter の --collector.textfile.directory（ロール node_exporter）と合わせる
TEXTFILE_DIR=${TB_WATCHDOG_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}

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

# NHI = PCI class 0x0c0340 (USB4 host interface)
nhi_devices() {
	for f in /sys/bus/pci/devices/*; do
		[ "$(cat "$f/class")" = 0x0c0340 ] && echo "$f"
	done
}

bound_domains() {
	for d in /sys/bus/thunderbolt/devices/domain*; do
		[ -e "$d" ] && basename "$d" | sed 's/^domain//'
	done
}

events_metrics=""
for dom in $(bound_domains); do
	n=$(awk -v d="domain=$dom" '$2 == d {print $1}' <<<"$counts")
	n=${n:-0}
	pci=$(basename "$(readlink -f "/sys/bus/thunderbolt/devices/domain$dom/..")")
	events_metrics+="tb_storm_watchdog_events{domain=\"$dom\",pci=\"$pci\"} $n"$'\n'
	streak_file="$STATE_DIR/domain$dom"
	if [ "$n" -le "$THRESHOLD" ]; then
		rm -f "$streak_file"
		continue
	fi
	streak=$(( $(cat "$streak_file" 2>/dev/null || echo 0) + 1 ))
	echo "$streak" > "$streak_file"
	log "domain$dom ($pci): $n events in ${SAMPLE_SEC}s (streak $streak/$CONSECUTIVE)" warning
	[ "$streak" -lt "$CONSECUTIVE" ] && continue

	# もう片方の NHI が unbind 済み (ドライバなし) なら、このホストを孤立させないように止める
	others_unbound=0
	for f in $(nhi_devices); do
		[ "$(basename "$f")" = "$pci" ] && continue
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
	rc=$?
	rm -f "$streak_file"
	log "domain$dom ($pci): unbind rc=$rc" crit
	# 再起動 (= /run が消える) まで tb_storm_watchdog_unbind_timestamp_seconds として出し続ける
	[ "$rc" = 0 ] && echo "$dom $(date +%s)" > "$STATE_DIR/unbound-$pci"
done

# node_exporter が読みかけのファイルを拾わないように、別名で書いてから置き換える
write_metrics() {
	echo "# HELP tb_storm_watchdog_events Thunderbolt events counted in the last ${SAMPLE_SEC}s sample (unbind above ${THRESHOLD}, ${CONSECUTIVE} runs in a row)."
	echo "# TYPE tb_storm_watchdog_events gauge"
	printf '%s' "$events_metrics"
	echo "# HELP tb_nhi_bound Whether a driver is bound to the USB4 host interface (PCI class 0x0c0340)."
	echo "# TYPE tb_nhi_bound gauge"
	for f in $(nhi_devices); do
		echo "tb_nhi_bound{pci=\"$(basename "$f")\"} $([ -e "$f/driver" ] && echo 1 || echo 0)"
	done
	# unbind していなければ HELP/TYPE も出さない
	for m in "$STATE_DIR"/unbound-*; do
		[ -e "$m" ] || continue
		if [ -z "${unbind_header:-}" ]; then
			echo "# HELP tb_storm_watchdog_unbind_timestamp_seconds When this watchdog unbound the NHI (kept until reboot)."
			echo "# TYPE tb_storm_watchdog_unbind_timestamp_seconds gauge"
			unbind_header=1
		fi
		read -r d t < "$m"
		echo "tb_storm_watchdog_unbind_timestamp_seconds{domain=\"$d\",pci=\"${m##*/unbound-}\"} $t"
	done
}
if mkdir -p "$TEXTFILE_DIR"; then
	tmp="$TEXTFILE_DIR/.tb-storm-watchdog.prom.$$"
	write_metrics > "$tmp" && mv "$tmp" "$TEXTFILE_DIR/tb-storm-watchdog.prom"
fi
