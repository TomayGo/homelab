# 認証は環境変数 PROXMOX_VE_ENDPOINT / PROXMOX_VE_API_TOKEN（値は proxmox-token.enc.yaml を sops -d して渡す）
# PVE の証明書は自己署名なので検証しない
provider "proxmox" {
  insecure = true
}
