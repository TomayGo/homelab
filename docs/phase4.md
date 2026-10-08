# Phase 4 実施記録（2026-10-09、apply前で停止中）

## 構成（`tofu/proxmox/`）

- provider：`bpg/proxmox` 0.116.0
- 認証：`source env.sh`で、`proxmox-token.enc.yaml`（SOPS）から`PROXMOX_VE_ENDPOINT`と`PROXMOX_VE_API_TOKEN`を読み込む（`iac-tofu@pve!tofu`）
- PVEへのSSHは使っていない（bpgのSSH設定は不要だった）
- `proxmox_virtual_environment_vm.talos`：`for_each`で3台（pve-1/201、pve-2/202、pve-3/203）。`import.tf`で取り込む
- 安全装置（手順書4-3）
  - `reboot_after_update = false`
  - `prevent_destroy = true`
  - `ignore_changes = [node_name, cdrom]`
  - `migrate = false`
- Talos VMがProxmox HAの対象外であることを確認した（HAは`vm:106`だけ）

## importで分かったこと

- `-generate-config-out`のHCLには、`affinity = ""`、`units = 0`、`hugepages = ""`などの空の値が入っていて、そのままでは検証に通らない。必要な属性だけを手で書き直した
- `ide2`のCD-ROM（`local:iso/talos-v1.13.6-qemu-guest-agent-amd64.iso`）は、importしてもstateに入らない
  - `cdrom`ブロックを書くと`+ cdrom { enabled = false }`の差分になり、applyでISOが外れるおそれがある
  - このため管理対象から外した（`ignore_changes`）
- `reboot_after_update`は、import直後のstateでは`true`になる。HCLの`false`との差は、stateだけの更新である（PVE側には存在しない値）

## 差分の確認結果

- `tofu plan`：`3 to import, 0 to add, 3 to change, 0 to destroy`。3つのchangeは、すべて`reboot_after_update: true -> false`だけ
- `must be replaced`は出ていない

## 残り（要確認）

- [ ] `tofu apply`（importの確定と、stateの`reboot_after_update`の更新だけ）
- [ ] apply後に`tofu plan`が`No changes`になることを確認する
- [ ] 暗号化された`terraform.tfstate`をコミットする
