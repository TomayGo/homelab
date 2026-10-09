#!/bin/sh
# R2 へのバックアップを有効にする（手順書 Phase 2）。リポジトリのファイルを書き換えるだけで、適用はしない。
#   1. 5つの namespace（dns, monitoring, ai, pricetracker, netbox）に Secret r2-backup を SOPS で作る
#   2. CNPG の ObjectStore / ScheduledBackup を manifests/ に入れ、Cluster に barman-cloud プラグインを足す
#   3. PVC バックアップの CronJob の suspend を外す
# 終わったら git diff を確認してコミットし、Argo CD で sync する（docs/phase2-plan.md）
set -eu
cd "$(git rev-parse --show-toplevel)"

printf 'R2 account ID: '; read -r R2_ACCOUNT_ID
printf 'R2 bucket: '; read -r R2_BUCKET
printf 'R2 access key ID: '; read -r R2_KEY_ID
stty -echo 2>/dev/null || true; printf "R2 secret access key: "; read -r R2_SECRET; stty echo 2>/dev/null || true; echo
export R2_ACCOUNT_ID R2_BUCKET R2_KEY_ID R2_SECRET

for pair in adguard-home:dns kube-prometheus-stack:monitoring openwebui:ai pricetracker:pricetracker netbox:netbox; do
  app=${pair%%:*}; ns=${pair#*:}
  out=k8s/apps/$app/manifests/r2-backup.enc.yaml
  NS=$ns python3 -I -c '
import json, os
e = os.environ
print(json.dumps({"apiVersion": "v1", "kind": "Secret",
  "metadata": {"name": "r2-backup", "namespace": e["NS"]}, "type": "Opaque",
  "stringData": {"R2_BUCKET": e["R2_BUCKET"],
                 "RCLONE_CONFIG_R2_ENDPOINT": "https://" + e["R2_ACCOUNT_ID"] + ".r2.cloudflarestorage.com",
                 "RCLONE_CONFIG_R2_ACCESS_KEY_ID": e["R2_KEY_ID"],
                 "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY": e["R2_SECRET"]}}))' |
    sops -e --filename-override "$out" --input-type json --output-type yaml /dev/stdin > "$out"
  grep -q r2-backup.enc.yaml "k8s/apps/$app/manifests/secret-generator.yaml" ||
    echo "  - ./r2-backup.enc.yaml" >> "k8s/apps/$app/manifests/secret-generator.yaml"
  sed -i 's/^      suspend: true$/      suspend: false/; s/^  suspend: true$/  suspend: false/' "k8s/apps/$app/manifests/pvc-backup.yaml"
  echo "secret + cronjob: $app ($ns)"
done

for pair in cloudnative-pg:cluster-grafana-db.yaml netbox:cluster-netbox-db.yaml; do
  app=${pair%%:*}; cluster=${pair#*:}
  sed "s/__R2_BUCKET__/$R2_BUCKET/; s/__R2_ACCOUNT_ID__/$R2_ACCOUNT_ID/" "k8s/apps/$app/backup-pending/backup-r2.yaml" > "k8s/apps/$app/manifests/backup-r2.yaml"
  grep -q backup-r2.yaml "k8s/apps/$app/manifests/kustomization.yaml" ||
    sed -i 's/^resources:$/resources:\n  - backup-r2.yaml/' "k8s/apps/$app/manifests/kustomization.yaml"
  python3 -I - "k8s/apps/$app/manifests/$cluster" <<'PY'
import sys, yaml
p = sys.argv[1]
d = yaml.safe_load(open(p))
d["spec"]["plugins"] = [{"name": "barman-cloud.cloudnative-pg.io", "isWALArchiver": True,
                         "parameters": {"barmanObjectName": "r2"}}]
open(p, "w").write(yaml.safe_dump(d, sort_keys=False))
PY
  echo "objectstore + plugin: $app"
done

unset R2_SECRET R2_KEY_ID
git status --short
