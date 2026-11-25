#!/bin/bash
# PVE の vzdump Google Drive 退避（ロール pve_gdrive_backup）用の SOPS 秘密情報ファイル
# ansible/group_vars/pve/gdrive.sops.yaml を対話で作る。リポジトリのファイルを書くだけで、適用はしない。
#
# 事前準備:
#   1. 先に rclone を pve-1 に入れておく（未導入なら `cd ansible && ansible-playbook playbooks/pve.yml --limit pve-1 --tags pve_gdrive_backup`）
#   2. Google Cloud Console で個人用プロジェクトを作り、Google Drive API を有効化する
#   3. OAuth 同意画面を「本番（In production）」にする（「テスト」のままだと refresh_token が 7 日で失効する）
#   4. 認証情報で「OAuth クライアント ID」（種類: デスクトップ アプリ）を作り、Client ID と Client Secret を控える
#   5. crypt 用のパスフレーズ 2 つ（password と salt 用の password2）をパスワードマネージャで生成・保管しておく
set -euo pipefail

cd "$(dirname "$0")/.."
out="ansible/group_vars/pve/gdrive.sops.yaml"

if ! command -v rclone >/dev/null 2>&1; then
  echo "rclone が見つかりません。先に pve-1 へ pve_gdrive_backup ロールを流して rclone を入れてください。" >&2
  exit 1
fi

printf 'Google OAuth Client ID: '
read -r CLIENT_ID
stty -echo 2>/dev/null || true
printf 'Google OAuth Client Secret: '
read -r CLIENT_SECRET
stty echo 2>/dev/null || true
echo

stty -echo 2>/dev/null || true
printf 'rclone crypt password（パスワードマネージャに保管済みのもの）: '
read -r CRYPT_PASS1
echo
printf 'rclone crypt password（確認のため再入力）: '
read -r CRYPT_PASS1_CONFIRM
echo
if [ "$CRYPT_PASS1" != "$CRYPT_PASS1_CONFIRM" ] || [ -z "$CRYPT_PASS1" ]; then
  stty echo 2>/dev/null || true
  echo "crypt password が空か一致しません。" >&2
  exit 1
fi

printf 'rclone crypt salt / password2（パスワードマネージャに保管済みのもの）: '
read -r CRYPT_PASS2
echo
printf 'rclone crypt salt / password2（確認のため再入力）: '
read -r CRYPT_PASS2_CONFIRM
stty echo 2>/dev/null || true
echo
if [ "$CRYPT_PASS2" != "$CRYPT_PASS2_CONFIRM" ] || [ -z "$CRYPT_PASS2" ]; then
  echo "crypt password2 が空か一致しません。" >&2
  exit 1
fi

tmpdir=$(mktemp -d)
chmod 0700 "$tmpdir"
trap 'rm -rf "$tmpdir"' EXIT
tmpconf="$tmpdir/rclone.conf"

echo
echo "=== OAuth トークン取得（スコープ: drive.file） ==="
echo "表示される 'rclone authorize \"drive\" \"...\"' を、ブラウザのある手元 PC で実行し、"
echo "出力されたトークン文字列を config_token> に貼り付けてください。"
echo
RCLONE_CONFIG="$tmpconf" rclone config create gdrive drive \
  client_id "$CLIENT_ID" \
  client_secret "$CLIENT_SECRET" \
  scope drive.file \
  config_is_local false

SEED_TOKEN=$(awk -F ' = ' '$1 == "token" { print substr($0, index($0, "=") + 2) }' "$tmpconf")
if [ -z "$SEED_TOKEN" ]; then
  echo "rclone.conf から token を取り出せませんでした。" >&2
  exit 1
fi

OBSCURED_PASS1=$(printf '%s\n' "$CRYPT_PASS1" | rclone obscure -)
OBSCURED_PASS2=$(printf '%s\n' "$CRYPT_PASS2" | rclone obscure -)
unset CRYPT_PASS1 CRYPT_PASS1_CONFIRM CRYPT_PASS2 CRYPT_PASS2_CONFIRM

echo "Google Drive（drive.file）への接続と crypt 設定を確認しています..."
RCLONE_CONFIG="$tmpconf" \
  RCLONE_CONFIG_GDRIVE_CRYPT_TYPE=crypt \
  RCLONE_CONFIG_GDRIVE_CRYPT_REMOTE="gdrive:proxmox-vzdump/dump" \
  RCLONE_CONFIG_GDRIVE_CRYPT_FILENAME_ENCRYPTION=off \
  RCLONE_CONFIG_GDRIVE_CRYPT_DIRECTORY_NAME_ENCRYPTION=false \
  RCLONE_CONFIG_GDRIVE_CRYPT_PASSWORD="$OBSCURED_PASS1" \
  RCLONE_CONFIG_GDRIVE_CRYPT_PASSWORD2="$OBSCURED_PASS2" \
  rclone mkdir gdrive_crypt:
echo "接続確認 OK（Google Drive 上に proxmox-vzdump/dump を作成・確認しました）"

mkdir -p "$(dirname "$out")"
export CLIENT_ID CLIENT_SECRET SEED_TOKEN OBSCURED_PASS1 OBSCURED_PASS2
python3 -I -c '
import json, os
e = os.environ
print(json.dumps({
    "gdrive_backup_client_id": e["CLIENT_ID"],
    "gdrive_backup_client_secret": e["CLIENT_SECRET"],
    "gdrive_backup_seed_token": e["SEED_TOKEN"],
    "gdrive_backup_crypt_password_obscured": e["OBSCURED_PASS1"],
    "gdrive_backup_crypt_password2_obscured": e["OBSCURED_PASS2"],
}))
' | sops -e --filename-override "$out" --input-type json --output-type yaml /dev/stdin > "$out"

unset CLIENT_ID CLIENT_SECRET SEED_TOKEN OBSCURED_PASS1 OBSCURED_PASS2
echo "wrote $out"
git status --short
