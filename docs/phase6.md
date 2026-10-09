# Phase 6 実施記録（2026-10-09、6-4以外は完了）

## 6-3 設定ファイルの記録（完了）

- `ansible/playbooks/collect-guests.yml`：`/etc/pve/nodes/*/{qemu-server,lxc}/*.conf`を`ansible/guest-configs/`に回収する（読み取りのみ）
- 2026-10-09の時点で11ゲスト分をコミットした。パスワードやトークンは含まれていない
- 宣言的な管理はしない。変更履歴と、復元時の参照元にする。ゲストの設定を変えたら、このplaybookを実行してコミットする

## 6-2 HA（完了）

- `playbooks/ha.yml`を本実行した（2026-10-09、ユーザー承認後）
  - HA resource `vm:106`：`comment game server`、`max_relocate 1`、`max_restart 1`、`state started`
    - `max_*`はPVEの既定値と同じなので、動作は変わらない
    - モジュールは`comment`、`max_relocate`、`max_restart`を常に送って比べる。コメントを空にすると毎回changedになるので、コメントを付けた
  - HA rule `mc-prefer-pve-1`：node-affinity、`pve-1:2,pve-2:1,pve-3:1`、非strict。mcはpve-1で動いていたので、移動は起きなかった
  - 2回目の実行は`changed=0`（冪等）
- 未確認事項#12の結果：community.proxmox 2.1.0の`proxmox_cluster_ha_resources`と`proxmox_cluster_ha_rules`で管理できる。ruleのモジュールだけがcheck modeに対応している。どちらもproxmoxer 2.3以上が必要（`/opt/iac-venv`）

## 6-1 ゲストの定義（完了）

### 未確認事項#11の結果

使い捨てのテストVM（VMID 990、起動しない。`hostpci0`と`hostpci1`に未使用のデバイスを設定）で確認し、確認後に削除した。

- `hostpci`を書かずに`proxmox_kvm`の`update: true`でcores、memory、descriptionを変えても、**`hostpci0`と`hostpci1`は残った**
- モジュールは指定した項目だけをPUTする。`smbios1`や`vmgenid`などは変わらない
- ただし、**同じ内容で2回目を実行してもchangedになる**（毎回PUTする。冪等でない）。check modeにも対応していない

### 構成

- `vars/guests.yml`：8ゲスト（VM 101 dtv、103 ap、106 mc、LXC 500、801〜803、903）の管理項目。回収した設定から生成した。Talos VMは`tofu/proxmox`で管理するので含めない
  - 管理する項目（VM）：name、cores、sockets、cpu、memory、balloon、onboot、agent、bios、machine、ostype、scsihw、numa、boot、net*
  - 管理する項目（LXC）：hostname、cores、memory、swap、onboot、features、nameserver、net*、ostype
  - 管理しない項目：ディスク、`hostpci*`、`usb*`、`dev*`（パススルー）、`smbios1`、`vmgenid`
- `playbooks/guests.yml`
  - `proxmox_vm_info`（読み取り専用）で現在の設定を取得し、フィルタ`config_drift`で違う項目だけを取り出す
  - 違いがあれば、その項目だけを`PUT /nodes/<node>/<type>/<vmid>/config`で更新する
  - 上記の理由から、`proxmox_kvm`と`proxmox`は使っていない
- 結果
  - `--check --diff`：8ゲストとも差分なし（`changed=0`）
  - わざと違う定義（mcのmemory）を渡したcheck modeでは、差分を検出し、更新はスキップされた
  - 本実行：`changed=0`。ゲストの設定ファイルのハッシュも変わらなかった

### 気づいたこと

- **LXC 801（llama-rpc-1、停止中）は固定IPが`192.168.1.90/24`**。MetalLBのプール（.90〜.99、Grafanaが.90を使っている）と重なっているので、起動するとIPが衝突する。`nameserver 192.168.1.31`も古い可能性がある
- VM 101 dtvに、未使用のディスク（`unused0: vm-101-disk-0`、`unused1: vm-101-disk-2`、各4MB）が残っている

## 6-4 ゲストの内部（未着手：接続方法が決まっていない）

| ゲスト | 接続方法 | 内容 |
|---|---|---|
| 103 ap | Tailscale SSHのみ（LANの22番は閉じている） | hostapd、netplan、br0 |
| 106 mc | Tailscale SSHのみ（LANの22番は閉じている。tailnetの22番はTailscale SSHが受ける） | ゲームサーバのOS |
| 500 discordbots | `pct exec 500`（開発用LXC、HA対象外） | 開発環境。本番のpricetrackerはk8sに移した |

- Tailscale SSHは、ACLが`check`モードで、ブラウザでの承認がないと入れない。pve-1から非対話で試すと、承認待ちのまま止まる
- 進め方の候補
  1. 作業のたびにTailscale SSHのcheckを承認する（承認は一定時間有効）
  2. tailnetのACLで、pve-1（またはタグ）から2台へのSSHを`accept`にする
  3. 2台でsshdをLANに開け、pve-1の鍵だけを許可する
