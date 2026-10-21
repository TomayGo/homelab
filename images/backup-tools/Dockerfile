# PVC バックアップ用のツールイメージ（tar → zstd → R2）。k8s/apps/*/manifests/pvc-backup.yaml の CronJob で使う
# snap-backup はスナップショットとバックアップ Job を作る側で、kubectl を使う
FROM alpine:3.24.2
# ベースイメージ同梱の ca-certificates-bundle はイメージ作成時点の版のまま残るので、apk upgrade で先にリポジトリの最新に上げる
# （2026-10 の eMudhra 中間 CA 鍵侵害の対応。3.24 では ca-certificates 20261020-r0 以降が入る）
RUN apk upgrade --no-cache \
 && apk add --no-cache --upgrade zstd sqlite rclone tar ca-certificates tzdata kubectl
COPY pvc-backup.sh /usr/local/bin/pvc-backup
COPY snap-backup.sh /usr/local/bin/snap-backup
ENTRYPOINT ["/bin/sh", "/usr/local/bin/pvc-backup"]
