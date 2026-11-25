#!/bin/bash
# pve/data（local-lvm）の Data% と Meta% を node_exporter の textfile collector に書き出す。
# ceph-osd の 384GiB LV と vzdump-stage の 96GiB LV が同じ thin pool に同居しており、
# Data% と Meta% のどちらが枯渇しても OSD ごと止まるため、両方を監視する。
set -euo pipefail

TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
[ -d "$TEXTFILE_DIR" ] || exit 0

out="# HELP pve_lvm_thinpool_data_ratio Allocated data ratio (0.0-1.0) of LVM thin pool."$'\n'
out+="# TYPE pve_lvm_thinpool_data_ratio gauge"$'\n'
out+="# HELP pve_lvm_thinpool_metadata_ratio Allocated metadata ratio (0.0-1.0) of LVM thin pool."$'\n'
out+="# TYPE pve_lvm_thinpool_metadata_ratio gauge"$'\n'

while read -r vg lv data_pct meta_pct; do
  [ -n "$vg" ] || continue
  data_ratio=$(LC_ALL=C awk -v p="$data_pct" 'BEGIN { printf "%.4f", p / 100.0 }')
  meta_ratio=$(LC_ALL=C awk -v p="$meta_pct" 'BEGIN { printf "%.4f", p / 100.0 }')
  out+="pve_lvm_thinpool_data_ratio{vg=\"${vg}\",lv=\"${lv}\"} ${data_ratio}"$'\n'
  out+="pve_lvm_thinpool_metadata_ratio{vg=\"${vg}\",lv=\"${lv}\"} ${meta_ratio}"$'\n'
done < <(LC_ALL=C LVM_SUPPRESS_FD_WARNINGS=1 lvs --noheadings -o vg_name,lv_name,data_percent,metadata_percent --select 'lv_attr=~^t' 2>/dev/null)

tmp=$(mktemp "$TEXTFILE_DIR/.lvm_thinpool.prom.XXXXXX")
printf '%s' "$out" > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$TEXTFILE_DIR/lvm_thinpool.prom"
