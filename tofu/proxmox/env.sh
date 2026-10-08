# 使い方: source env.sh （tofu/proxmox で実行）
export TF_VAR_state_passphrase="$(cat ~/.config/homelab/tofu-state-passphrase)"
export PROXMOX_VE_ENDPOINT="$(sops -d --extract '["proxmox_api_endpoint"]' proxmox-token.enc.yaml)"
export PROXMOX_VE_API_TOKEN="$(sops -d --extract '["proxmox_api_token"]' proxmox-token.enc.yaml)"
