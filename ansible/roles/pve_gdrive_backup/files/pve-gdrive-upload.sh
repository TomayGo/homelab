#!/bin/bash
# /var/lib/vz-stage/dump に出力された vzdump アーカイブを rclone crypt 経由で Google Drive へ送り、
# cryptcheck で検証してからクラウド側の世代管理（VMID ごとに keep-last=3）を行う。
#
# 起動経路:
#   1. vzdump-gdrive-hook.sh の job-end / job-abort から systemctl start --no-block
#   2. pve-gdrive-upload.timer（2 時間ごと）による未転送アーカイブの再試行とメトリクス更新
set -euo pipefail
shopt -s nullglob

STATE_DIR=/var/lib/pve-gdrive-backup
UPLOADED_DIR="$STATE_DIR/uploaded"
VMIDS_DIR="$STATE_DIR/vmids"
RCLONE_CONF="$STATE_DIR/rclone.conf"
ENV_FILE=/etc/pve-gdrive-backup/rclone.env
TEXTFILE_DIR=/var/lib/node_exporter/textfile_collector

mkdir -p "$UPLOADED_DIR" "$VMIDS_DIR"
chmod 0700 "$STATE_DIR" "$UPLOADED_DIR" "$VMIDS_DIR"

exec 9>/run/pve-gdrive-upload.lock
if ! flock -n 9; then
  logger -t pve-gdrive-upload "already running, skipping"
  exit 0
fi

write_metrics() {
  local configured="$1"
  [ -d "$TEXTFILE_DIR" ] || return 0

  local out=""
  out+="# HELP pve_vzdump_gdrive_configured 1 if rclone Google Drive credentials are installed."$'\n'
  out+="# TYPE pve_vzdump_gdrive_configured gauge"$'\n'
  out+="pve_vzdump_gdrive_configured ${configured}"$'\n'
  out+="# HELP pve_vzdump_gdrive_last_run_success 1 if the latest backup and Drive sync for this VMID succeeded."$'\n'
  out+="# TYPE pve_vzdump_gdrive_last_run_success gauge"$'\n'
  out+="# HELP pve_vzdump_gdrive_last_success_timestamp_seconds Unix time of the last verified Drive backup for this VMID."$'\n'
  out+="# TYPE pve_vzdump_gdrive_last_success_timestamp_seconds gauge"$'\n'

  local f vmid val
  for f in "$VMIDS_DIR"/*.success; do
    vmid=$(basename "$f" .success)
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    val=$(cat "$f" 2>/dev/null || echo 0)
    out+="pve_vzdump_gdrive_last_run_success{vmid=\"${vmid}\"} ${val}"$'\n'
  done
  for f in "$VMIDS_DIR"/*.last_success; do
    vmid=$(basename "$f" .last_success)
    [[ "$vmid" =~ ^[0-9]+$ ]] || continue
    val=$(cat "$f" 2>/dev/null || echo 0)
    out+="pve_vzdump_gdrive_last_success_timestamp_seconds{vmid=\"${vmid}\"} ${val}"$'\n'
  done

  out+="# HELP pve_vzdump_gdrive_last_check_timestamp_seconds Unix time of the last uploader check."$'\n'
  out+="# TYPE pve_vzdump_gdrive_last_check_timestamp_seconds gauge"$'\n'
  out+="pve_vzdump_gdrive_last_check_timestamp_seconds $(date +%s)"$'\n'

  local tmp
  tmp=$(mktemp "$TEXTFILE_DIR/.pve_vzdump_gdrive.prom.XXXXXX")
  printf '%s' "$out" > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$TEXTFILE_DIR/pve_vzdump_gdrive.prom"
}

if [ ! -r "$ENV_FILE" ] || [ ! -r "$RCLONE_CONF" ]; then
  write_metrics 0
  exit 0
fi

trap 'write_metrics 1' EXIT

set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a
export RCLONE_CONFIG="$RCLONE_CONF"

STAGE_MOUNT="${PVE_GDRIVE_STAGE_MOUNT:-/var/lib/vz-stage}"
DUMP_DIR="${STAGE_MOUNT}/dump"
KEEP_LAST="${PVE_GDRIVE_KEEP_LAST:-3}"
BWLIMIT="${PVE_GDRIVE_BWLIMIT:-25M}"

# vzdump の実行中（/var/run/vzdump.lock がロック中）は触らない。
# job-end 直後は vzdump が最後の通知処理で 1 秒ほどロックを握ったままのことがあるため最大 30 秒待つ。
# 本当にバックアップ中なら 30 秒で抜けて job-end からの再起動に任せる
if [ -e /var/run/vzdump.lock ] && ! flock -w 30 /var/run/vzdump.lock true 2>/dev/null; then
  logger -t pve-gdrive-upload "vzdump is currently running, deferring until job-end"
  exit 0
fi

# HA（vm:106 など）で別ノードへ移ったゲストが、このノードのローカル領域に古い世代を残し続けないように掃除する。
# 条件: 自ノード（/etc/pve/local）には居ないが、クラスタ内の他ノード（/etc/pve/nodes/*）には存在するゲスト。
# （クラスタから完全に削除したゲストのダンプは勝手に消さない。また未アップロードのファイルは絶対に消さない）
guest_moved_to_peer() {
  local vmid="$1"
  if [ -e "/etc/pve/local/qemu-server/${vmid}.conf" ] || [ -e "/etc/pve/local/lxc/${vmid}.conf" ]; then
    return 1
  fi
  local p
  for p in /etc/pve/nodes/*/qemu-server/"${vmid}.conf" /etc/pve/nodes/*/lxc/"${vmid}.conf"; do
    [ -e "$p" ] && return 0
  done
  return 1
}

need_trim=0

for state_file in "$VMIDS_DIR"/*.success "$VMIDS_DIR"/*.last_success; do
  [ -e "$state_file" ] || continue
  vmid="${state_file##*/}"
  vmid="${vmid%%.*}"
  if [[ "$vmid" =~ ^[0-9]+$ ]] && guest_moved_to_peer "$vmid"; then
    rm -f "$VMIDS_DIR/${vmid}.success" "$VMIDS_DIR/${vmid}.last_success"
  fi
done

if [ -d "$DUMP_DIR" ]; then
  for arch in "$DUMP_DIR"/vzdump-*.vma.zst "$DUMP_DIR"/vzdump-*.tar.zst; do
    base=$(basename "$arch")
    if [[ "$base" =~ ^vzdump-(qemu|lxc)-([0-9]+)-[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}\.(vma|tar)\.zst$ ]]; then
      vmid="${BASH_REMATCH[2]}"
      if guest_moved_to_peer "$vmid" && [ -e "$UPLOADED_DIR/$base" ]; then
        stem="${base%.vma.zst}"
        stem="${stem%.tar.zst}"
        logger -t pve-gdrive-upload "removing migrated guest vmid=${vmid} local dump ${base} (already on Drive)"
        rm -f "$arch" "${arch}.notes" "${DUMP_DIR}/${stem}.log"
        need_trim=1
      fi
    fi
  done
fi

rclone_common=(
  --bwlimit "$BWLIMIT"
  --drive-chunk-size 32M
  --drive-stop-on-upload-limit
  --transfers 1
  --checkers 2
  --stats 60s
)

overall_rc=0

if [ -d "$DUMP_DIR" ]; then
  for arch in "$DUMP_DIR"/vzdump-*.vma.zst "$DUMP_DIR"/vzdump-*.tar.zst; do
    base=$(basename "$arch")
    if ! [[ "$base" =~ ^vzdump-(qemu|lxc)-([0-9]+)-[0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2}\.(vma|tar)\.zst$ ]]; then
      continue
    fi
    vmtype="${BASH_REMATCH[1]}"
    vmid="${BASH_REMATCH[2]}"

    if [ -e "$UPLOADED_DIR/$base" ]; then
      continue
    fi

    stem="${base%.vma.zst}"
    stem="${stem%.tar.zst}"
    notes_file="${arch}.notes"
    log_file="${DUMP_DIR}/${stem}.log"

    logger -t pve-gdrive-upload "uploading ${base} (vmid=${vmid}) to gdrive_crypt:"
    upload_ok=1
    if ! rclone copy "$arch" gdrive_crypt: "${rclone_common[@]}"; then
      upload_ok=0
    fi
    if [ "$upload_ok" -eq 1 ] && [ -f "$notes_file" ]; then
      rclone copy "$notes_file" gdrive_crypt: "${rclone_common[@]}" || upload_ok=0
    fi
    if [ "$upload_ok" -eq 1 ] && [ -f "$log_file" ]; then
      rclone copy "$log_file" gdrive_crypt: "${rclone_common[@]}" || upload_ok=0
    fi

    if [ "$upload_ok" -eq 1 ]; then
      logger -t pve-gdrive-upload "verifying ${base} via rclone cryptcheck"
      if ! rclone cryptcheck "$DUMP_DIR" gdrive_crypt: --one-way --include "$base" --checkers 2; then
        logger -t pve-gdrive-upload "cryptcheck FAILED for ${base}"
        upload_ok=0
      fi
    fi

    if [ "$upload_ok" -ne 1 ]; then
      logger -t pve-gdrive-upload "sync failed for ${base} (vmid=${vmid})"
      echo 0 > "$VMIDS_DIR/${vmid}.success"
      overall_rc=1
      continue
    fi

    touch "$UPLOADED_DIR/$base"
    date +%s > "$VMIDS_DIR/${vmid}.last_success"
    echo 1 > "$VMIDS_DIR/${vmid}.success"
    logger -t pve-gdrive-upload "verified ${base} on gdrive_crypt:"

    # 検証済みのアップロードが通ったときだけ、当該 VMID の古い世代を keep-last 数に揃えて消す。
    # ゴミ箱に 30 日溜まると約 670GiB 余計に食うため --drive-use-trash=false で直接消す。
    mapfile -t remote_archives < <(
      rclone lsf gdrive_crypt: --files-only \
        --include "vzdump-${vmtype}-${vmid}-*.vma.zst" \
        --include "vzdump-${vmtype}-${vmid}-*.tar.zst" | LC_ALL=C sort
    )
    if [ "${#remote_archives[@]}" -gt "$KEEP_LAST" ]; then
      to_delete=$(( ${#remote_archives[@]} - KEEP_LAST ))
      for (( i = 0; i < to_delete; i++ )); do
        old="${remote_archives[$i]}"
        [ -n "$old" ] || continue
        old_stem="${old%.vma.zst}"
        old_stem="${old_stem%.tar.zst}"
        logger -t pve-gdrive-upload "pruning old remote backup ${old} (keep-last=${KEEP_LAST})"
        rclone deletefile --drive-use-trash=false "gdrive_crypt:${old}.notes" >/dev/null 2>&1 || true
        rclone deletefile --drive-use-trash=false "gdrive_crypt:${old_stem}.log" >/dev/null 2>&1 || true
        if ! rclone deletefile --drive-use-trash=false "gdrive_crypt:${old}"; then
          logger -t pve-gdrive-upload "warning: failed to delete old remote backup ${old}"
        fi
      done
    fi
  done
fi

find "$UPLOADED_DIR" -type f -mtime +90 -delete 2>/dev/null || true

if [ "$need_trim" -eq 1 ] && mountpoint -q "$STAGE_MOUNT"; then
  fstrim "$STAGE_MOUNT" >/dev/null 2>&1 || true
fi

exit "$overall_rc"
