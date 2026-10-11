# PVC バックアップ用のツールイメージ（tar → zstd → R2）。k8s/apps/*/manifests/pvc-backup.yaml の CronJob で使う
# snap-backup はスナップショットとバックアップ Job を作る側で、kubectl を使う
FROM alpine:3.24.2
RUN apk add --no-cache zstd sqlite rclone tar ca-certificates tzdata kubectl
COPY pvc-backup.sh /usr/local/bin/pvc-backup
COPY snap-backup.sh /usr/local/bin/snap-backup
ENTRYPOINT ["/bin/sh", "/usr/local/bin/pvc-backup"]
