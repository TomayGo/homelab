# Phase 4 実施記録（2026-10-09完了）

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

## apply（2026-10-09、ユーザー承認後）

- planを保存し、内容がimport 3つと`reboot_after_update`の更新3つだけであることを確認してからapplyした
- applyの前後で、`/etc/pve/nodes/*/qemu-server/20{1,2,3}.conf`のハッシュは完全に一致した（VMの設定は変わっていない）。VMは動いたままで、k8sの3ノードもReady
- apply後の`tofu plan`は`No changes`
- 暗号化された`terraform.tfstate`をコミットした

## Phase 4の完了条件

- [x] `tofu plan`が`No changes`
- [x] 全Talos VMに`prevent_destroy`が付いている
