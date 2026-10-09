#!/bin/sh
# R2 の無料枠アラート用に、Cloudflare API トークンを Secret r2-usage-exporter（SOPS）として書く。適用はしない。
# トークンは Cloudflare ダッシュボードの「My Profile → API Tokens → Create Custom Token」で作る。
#   権限: Account / Account Analytics / Read   対象: R2 を使っているアカウント
# アカウント ID は既存の Secret r2-backup のエンドポイントから取るので、入力はトークンだけ。
# 終わったら git diff を確認してコミットし、Argo CD で kube-prometheus-stack を sync する
set -eu
cd "$(dirname "$0")/.."
dir=k8s/apps/kube-prometheus-stack/manifests
out=$dir/r2-usage-exporter.enc.yaml

CF_ACCOUNT_ID=$(sops -d --extract '["stringData"]["RCLONE_CONFIG_R2_ENDPOINT"]' "$dir/r2-backup.enc.yaml" |
  sed -E 's#^https://([0-9a-f]+)\.r2\.cloudflarestorage\.com.*#\1#')
case $CF_ACCOUNT_ID in
  *[!0-9a-f]* | "") echo "r2-backup のエンドポイントからアカウント ID を取れなかった" >&2; exit 1 ;;
esac

stty -echo 2>/dev/null || true; printf 'Cloudflare API token (Account Analytics: Read): '; read -r CF_API_TOKEN; stty echo 2>/dev/null || true; echo
export CF_ACCOUNT_ID CF_API_TOKEN

# 書く前に、トークンでアカウントの R2 の数字が読めるか確かめる
python3 -I - <<'PY'
import datetime as dt, json, os, sys, urllib.request
# 期間は 31 日までしか指定できないので、直近 1 日だけ見る
since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
q = '{viewer{accounts(filter:{accountTag:"%s"}){r2StorageAdaptiveGroups(limit:1,filter:{datetime_geq:"%s"}){max{payloadSize}}}}}' % (os.environ["CF_ACCOUNT_ID"], since)
req = urllib.request.Request("https://api.cloudflare.com/client/v4/graphql",
    data=json.dumps({"query": q}).encode(),
    headers={"Authorization": "Bearer " + os.environ["CF_API_TOKEN"], "Content-Type": "application/json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=30))
except Exception as e:
    sys.exit(f"API に繋がらない: {e}")
if r.get("errors") or not r["data"]["viewer"]["accounts"]:
    sys.exit("トークンで読めない（権限 Account Analytics: Read と対象アカウントを確認）: " + json.dumps(r.get("errors"))[:300])
print("API check OK")
PY

python3 -I -c '
import json, os
e = os.environ
print(json.dumps({"apiVersion": "v1", "kind": "Secret",
  "metadata": {"name": "r2-usage-exporter", "namespace": "monitoring"}, "type": "Opaque",
  "stringData": {"CF_ACCOUNT_ID": e["CF_ACCOUNT_ID"], "CF_API_TOKEN": e["CF_API_TOKEN"]}}))' |
  sops -e --filename-override "$out" --input-type json --output-type yaml /dev/stdin > "$out"
unset CF_API_TOKEN

grep -q r2-usage-exporter.enc.yaml "$dir/secret-generator.yaml" ||
  echo "  - ./r2-usage-exporter.enc.yaml" >> "$dir/secret-generator.yaml"
echo "wrote $out"
git status --short
