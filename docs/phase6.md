# Phase 6 実施記録（2026-10-09、一部のみ）

## 6-3 設定ファイルの記録（完了）

- `ansible/playbooks/collect-guests.yml`：`/etc/pve/nodes/*/{qemu-server,lxc}/*.conf`を`ansible/guest-configs/`に回収する（読み取りのみ）
- 2026-10-09の時点で11ゲスト分をコミットした。パスワードやトークンは含まれていない
- 宣言的な管理はしない。変更履歴と、復元時の参照元にする。ゲストの設定を変えたら、このplaybookを実行してコミットする

## 6-2 HA（未確認事項#12の結果と、案）

- community.proxmox 2.1.0には、`proxmox_cluster_ha_resources`と`proxmox_cluster_ha_rules`（node-affinityとresource-affinity）がある。**HAはAnsibleで管理できる**
- check modeに対応しているのは`proxmox_cluster_ha_rules`だけ（diffも出る）。`proxmox_cluster_ha_resources`は非対応で、`--check`ではskipされる
- community.proxmoxはproxmoxer 2.3以上が必要。Debianの`python3-proxmoxer`は2.2.0なので、`/opt/iac-venv`のvenvを使う（`playbooks/ha.yml`の`ansible_python_interpreter`）
- 現状：HA resourceは`vm:106`だけ（2026-10-09にct:500とct:903を外した）。HA ruleは1つもない
- **案**（`playbooks/ha.yml`、未適用）：`mc-prefer-pve-1`。node-affinity、`pve-1:2,pve-2:1,pve-3:1`、非strict
  - `--check --diff`では、このruleを新規作成する差分が出る
  - 優先ノードをどこにするかは要確認

## 6-1 ゲストの定義（未着手、要確認）

- `community.proxmox.proxmox_kvm`（VM）と`community.proxmox.proxmox`（LXC）は、**check modeに対応していない**（`supports_check_mode=False`）。`--check --diff`では差分を確認できない
- このため、手順書の「`--check --diff`でchanged=0」という確認方法はこの2つには使えない。代わりの方法は次の2つ
  1. 読み取り専用の`proxmox_vm_info`で現状を取得し、定義と比べるplaybookを作る（差分の検出だけ）
  2. vzdumpかスナップショットを取ってから、実際に`update: true`で1台ずつ試す（未確認事項#11の`hostpci`の検証を兼ねる）
- `hostpci`を持つVMは`101 dtv`（780M iGPU、romfile）と`103 ap`（3デバイス）。手順書の方針どおり、タスクには書かない

## 6-4 ゲストの内部（未着手）

| ゲスト | 接続方法 | 内容 |
|---|---|---|
| 103 ap | Tailscale SSHのみ（sshdなし） | hostapd、netplan、br0 |
| 106 mc | 未確認 | ゲームサーバのOS |
| 500 discordbots | `pct exec 500`（開発用LXC、HA対象外） | 開発環境。本番のpricetrackerはk8sに移した |
| 801〜803 llama-rpc | `pct exec`（停止中） | - |

- NetBox（CT903）とAGHのLXC（CT100）は、もうLXCではない（k8sに移した、または削除済み）
