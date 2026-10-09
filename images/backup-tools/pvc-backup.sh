#!/bin/sh
# PVC の中身を tar → zstd → R2 に送り、新しいものから KEEP 世代だけ残す。
#
# 環境変数
#   BACKUP_NAME   R2 上の置き場所（例 dns/agh-primary → pvc/dns/agh-primary/<UTC時刻>.tar.zst）
#   SRC_DIR       バックアップするディレクトリ（既定 /src。PVC をこの下にマウントする）
#   EXCLUDES      除外するパス（SRC_DIR からの相対。空白区切り）
#   SQLITE_DBS    SQLite の DB（SRC_DIR からの相対。空白区切り）。動いている DB をそのまま tar すると
#                 壊れたコピーになりうるので、sqlite3 の .backup で取り直し、.sqlite-backup/<パス> に入れる
#   KEEP          残す世代数（既定 2）
#   ZSTD_LEVEL    既定 19。ZSTD_THREADS 既定 2
#   DRY_RUN       1 なら R2 に送らず、圧縮後のサイズと所要時間だけを出す（DRY_RUN_OUT にパスを渡すとアーカイブも残す）
#   R2_BUCKET と RCLONE_CONFIG_R2_*（Secret r2-backup）
set -eu

SRC_DIR=${SRC_DIR:-/src}
KEEP=${KEEP:-2}
LEVEL=${ZSTD_LEVEL:-19}
THREADS=${ZSTD_THREADS:-2}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
STAGE=$(mktemp -d)
START=$(date +%s)
: "${BACKUP_NAME:?BACKUP_NAME is required}"

set --
for e in ${EXCLUDES:-}; do
  set -- "$@" "--exclude=./$e"
done
for db in ${SQLITE_DBS:-}; do
  mkdir -p "$STAGE/.sqlite-backup/$(dirname "$db")"
  sqlite3 "$SRC_DIR/$db" ".backup '$STAGE/.sqlite-backup/$db'"
  set -- "$@" "--exclude=./$db" "--exclude=./$db-wal" "--exclude=./$db-shm" "--exclude=./$db-journal"
done

# GNU tar は、読んでいる途中でファイルが変わる（Prometheus の compaction など）と 1 で終わる。
# 1 は警告として扱い、2 以上だけを失敗にする
archive() {
  rc=0
  tar -cf - --warning=no-file-changed --warning=no-file-removed --ignore-failed-read \
    "$@" -C "$SRC_DIR" . -C "$STAGE" .sqlite-backup 2>"$STAGE/tar.err" || rc=$?
  if [ "$rc" -gt 1 ]; then
    cat "$STAGE/tar.err" >&2
    exit "$rc"
  fi
}

set -o pipefail
if [ "${DRY_RUN:-0}" = 1 ]; then
  archive "$@" | zstd -"$LEVEL" -T"$THREADS" -q -v -c 2>"$STAGE/zstd.err" | tee "${DRY_RUN_OUT:-/dev/null}" | wc -c >"$STAGE/size"
  echo "DRY_RUN ${BACKUP_NAME}: compressed=$(( $(cat "$STAGE/size") / 1048576 ))MiB seconds=$(( $(date +%s) - START ))"
  cat "$STAGE/zstd.err" >&2
  exit 0
fi

: "${R2_BUCKET:?R2_BUCKET is required}"
DEST="r2:${R2_BUCKET}/pvc/${BACKUP_NAME}"
archive "$@" | zstd -"$LEVEL" -T"$THREADS" -q -c | rclone rcat --s3-no-check-bucket "${DEST}/${STAMP}.tar.zst"

# 古い世代を消す（ファイル名は UTC 時刻なので、名前順＝時刻順）
rclone lsf --files-only "${DEST}/" | sort | awk -v keep="$KEEP" '{a[NR]=$0} END {for (i = 1; i <= NR - keep; i++) print a[i]}' |
  while read -r old; do
    rclone deletefile --s3-no-check-bucket "${DEST}/${old}"
    echo "deleted ${DEST}/${old}"
  done

echo "uploaded ${DEST}/${STAMP}.tar.zst seconds=$(( $(date +%s) - START ))"
rclone size "${DEST}/"
