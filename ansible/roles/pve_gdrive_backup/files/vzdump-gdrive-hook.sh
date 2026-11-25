#!/bin/bash
# Proxmox vzdump hook script for local-stage + async Google Drive (rclone crypt) offsite sync.
#
# VZDump.pm の実行順:
#   1. ローカル（/var/lib/vz-stage/dump）へアーカイブと .notes を出力
#   2. ローカルの prune-backups（keep-last=1）を実行
#   3. backup-end（失敗時は backup-abort）を呼ぶ  <-- まだ VM の backup lock が握られている
#   4. VM の lock を外し、確定した .log を書いて log-end を呼ぶ
#   5. 全対象ゲストが終わったら job-end（失敗時は job-abort）を呼ぶ
#
# backup-end の中で同期アップロードすると、数十 GiB の転送が終わるまで VM の lock が外れない。
# そのためここでは失敗記録と fstrim だけを行い、転送本体は job-end から pve-gdrive-upload.service を
# --no-block で起動して裏で流す。
set -euo pipefail

phase="${1:-}"
vmid="${3:-}"

STATE_DIR=/var/lib/pve-gdrive-backup
VMIDS_DIR="$STATE_DIR/vmids"
STAGE_MOUNT=/var/lib/vz-stage
if [ -r /etc/pve-gdrive-backup/rclone.env ]; then
  # shellcheck source=/dev/null
  . /etc/pve-gdrive-backup/rclone.env
  STAGE_MOUNT="${PVE_GDRIVE_STAGE_MOUNT:-/var/lib/vz-stage}"
fi

mkdir -p "$VMIDS_DIR"

case "$phase" in
  backup-abort)
    if [[ "$vmid" =~ ^[0-9]+$ ]]; then
      echo 0 > "$VMIDS_DIR/${vmid}.success"
      logger -t vzdump-gdrive-hook "local vzdump aborted for vmid=${vmid}"
    fi
    ;;
  job-end|job-abort)
    # ローカルの keep-last=1 prune で空いたブロックを pve/data thin pool にすぐ返す
    if mountpoint -q "$STAGE_MOUNT"; then
      fstrim "$STAGE_MOUNT" >/dev/null 2>&1 || true
    fi
    systemctl start --no-block pve-gdrive-upload.service || true
    ;;
esac
