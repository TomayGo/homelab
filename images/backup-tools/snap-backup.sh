#!/bin/sh
# PVC のスナップショットからクローンを作り、そのクローンをバックアップする。
# RBD の PVC は ReadWriteOnce なので、元の PVC を直接マウントするとバックアップ Pod が
# 元の Pod と同じノードに縛られ、そのノードが満杯だと Pending のまま終わる（2026-10-12）。
# クローンならどのノードでもマウントできる。
#
#   1. SNAP_PVCS の PVC ごとに VolumeSnapshot <pvc>-backup を作り、readyToUse を待つ
#   2. RUN_CRONJOB（suspend: true のテンプレート）から Job を作る。その Job は generic ephemeral volume で
#      スナップショットからクローン PVC を作り、pvc-backup を動かす
#   3. Job の終了を待ってログをこの Pod に写し、Job を消す（Pod ごとクローン PVC も消える）。スナップショットも消す
#
# 環境変数
#   SNAP_PVCS     スナップショットを取る PVC（空白区切り）
#   RUN_CRONJOB   バックアップ本体の CronJob
#   SNAP_CLASS    VolumeSnapshotClass（既定 ceph-rbd）
#   RUN_TIMEOUT   バックアップ本体を待つ秒数（既定 5400）
set -eu

: "${SNAP_PVCS:?SNAP_PVCS is required}"
: "${RUN_CRONJOB:?RUN_CRONJOB is required}"
CLASS=${SNAP_CLASS:-ceph-rbd}
TIMEOUT=${RUN_TIMEOUT:-5400}
NS=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
JOB=

cleanup() {
  if [ -n "$JOB" ]; then
    kubectl -n "$NS" delete job "$JOB" --ignore-not-found --cascade=foreground --wait=true || true
  fi
  for p in $SNAP_PVCS; do
    kubectl -n "$NS" delete volumesnapshot "$p-backup" --ignore-not-found --wait=false || true
  done
}
trap cleanup EXIT

for p in $SNAP_PVCS; do
  # 前回の残りがあれば消してから作る
  kubectl -n "$NS" delete volumesnapshot "$p-backup" --ignore-not-found --wait=true
  kubectl -n "$NS" create -f - <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $p-backup
  labels:
    app.kubernetes.io/managed-by: snap-backup
spec:
  volumeSnapshotClassName: $CLASS
  source:
    persistentVolumeClaimName: $p
EOF
done
for p in $SNAP_PVCS; do
  kubectl -n "$NS" wait "volumesnapshot/$p-backup" --for=jsonpath='{.status.readyToUse}'=true --timeout=600s
done
echo "snapshots ready: $SNAP_PVCS"

JOB="$RUN_CRONJOB-$(date +%s)"
kubectl -n "$NS" create job "$JOB" --from="cronjob/$RUN_CRONJOB"

# 成功か失敗のどちらかになるまで待つ
failed=
deadline=$(( $(date +%s) + TIMEOUT ))
while :; do
  ok=$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.succeeded}' || true)
  ng=$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' || true)
  [ "${ok:-0}" -ge 1 ] && break
  [ "$ng" = True ] && { failed=1; break; }
  [ "$(date +%s)" -lt "$deadline" ] || { echo "timeout waiting for $JOB" >&2; failed=1; break; }
  sleep 10
done

kubectl -n "$NS" logs "job/$JOB" --all-containers --tail=-1 || true
if [ -n "$failed" ]; then
  echo "$JOB failed" >&2
  exit 1
fi
echo "$JOB succeeded"
