# PVC バックアップ用のツールイメージ（tar → zstd → R2）。k8s/apps/*/manifests/pvc-backup.yaml の CronJob で使う
FROM alpine:3.24.2
RUN apk add --no-cache zstd sqlite rclone tar ca-certificates tzdata
COPY pvc-backup.sh /usr/local/bin/pvc-backup
ENTRYPOINT ["/bin/sh", "/usr/local/bin/pvc-backup"]
