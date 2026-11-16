#!/bin/bash
# /mnt/pve/ の下の CIFS マウント（PVE の cifs ストレージ）が "Stale file handle" になっていたら付け直す。
#
# PC がスリープすると SMB の接続が切れ、復帰後もマウントだけが壊れたまま残ることがある。PVE は、マウントが
# あれば壊れていても付け直さないので、そのストレージを使う vzdump が "unable to activate storage" で失敗し続ける
# （2026-11-01〜11-16 の pc-backups が、3 ノードともこの状態だった）。
#
# 直すのは ESTALE のときだけ。PC がスリープ中で応答がない（stat がタイムアウトする）ときは触らない。
# 付け直しても繋がらないし、復帰すれば元のマウントがそのまま使えることもあるため。
#
# node_exporter の textfile collector に次を書く:
#   pve_cifs_mount_ok{storage}                 最後の確認で stat が通ったら 1
#   pve_cifs_stale_remounts_total{storage}     ESTALE を見つけて付け直した回数
#   pve_cifs_remount_last_check_timestamp_seconds
set -u

TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector
STATE_DIR=/var/lib/cifs-stale-remount
mkdir -p "$STATE_DIR"

metrics=""
add() { metrics+="$1"$'\n'; }
add "# HELP pve_cifs_mount_ok 1 if stat on the CIFS mount succeeded at the last check."
add "# TYPE pve_cifs_mount_ok gauge"

declare -A remounts=()

while read -r mp; do
  [ -n "$mp" ] || continue
  id=$(basename "$mp")
  count_file="$STATE_DIR/$id.remounts"
  remounts[$id]=$(cat "$count_file" 2>/dev/null || echo 0)

  err=$(timeout 15 stat -t "$mp" 2>&1 >/dev/null)
  rc=$?
  if [ $rc -ne 0 ] && [[ $err == *"Stale file handle"* ]]; then
    logger -t cifs-stale-remount "storage $id: $mp is stale, lazy-unmounting and letting PVE remount it"
    umount -l "$mp"
    # pvesm status がストレージを activate する（マウントし直す）
    timeout 60 pvesm status --storage "$id" >/dev/null 2>&1
    remounts[$id]=$((remounts[$id] + 1))
    echo "${remounts[$id]}" > "$count_file"
    err=$(timeout 15 stat -t "$mp" 2>&1 >/dev/null)
    rc=$?
    if [ $rc -eq 0 ]; then
      logger -t cifs-stale-remount "storage $id: remounted"
    else
      logger -t cifs-stale-remount "storage $id: still not usable after remount (rc=$rc): $err"
    fi
  fi
  add "pve_cifs_mount_ok{storage=\"$id\"} $([ $rc -eq 0 ] && echo 1 || echo 0)"
done < <(awk '$3 == "cifs" && $2 ~ "^/mnt/pve/" {print $2}' /proc/mounts | sort -u)

add "# HELP pve_cifs_stale_remounts_total Number of times a stale CIFS mount was lazily unmounted and remounted."
add "# TYPE pve_cifs_stale_remounts_total counter"
for id in "${!remounts[@]}"; do
  add "pve_cifs_stale_remounts_total{storage=\"$id\"} ${remounts[$id]}"
done
add "# HELP pve_cifs_remount_last_check_timestamp_seconds Unix time of the last check."
add "# TYPE pve_cifs_remount_last_check_timestamp_seconds gauge"
add "pve_cifs_remount_last_check_timestamp_seconds $(date +%s)"

if [ -d "$TEXTFILE_DIR" ]; then
  tmp=$(mktemp "$TEXTFILE_DIR/.pve_cifs.prom.XXXXXX")
  printf '%s' "$metrics" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$TEXTFILE_DIR/pve_cifs.prom"
fi
