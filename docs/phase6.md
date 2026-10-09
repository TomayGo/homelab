# Phase 6 実施記録（2026-10-09完了）

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

- `vars/guests.yml`：4ゲスト（VM 101 dtv、103 ap、106 mc、LXC 500）の管理項目。回収した設定から生成した。作成時は801〜803を含む8ゲストだったが、削除に合わせて外した。903も2026-10-09の片付けで削除して外した。Talos VMは`tofu/proxmox`で管理するので含めない
  - 管理する項目（VM）：name、cores、sockets、cpu、memory、balloon、onboot、agent、bios、machine、ostype、scsihw、numa、boot、net*
  - 管理する項目（LXC）：hostname、cores、memory、swap、onboot、features、nameserver、net*、ostype
  - 管理しない項目：ディスク、`hostpci*`、`usb*`、`dev*`（パススルー）、`smbios1`、`vmgenid`
- `playbooks/guests.yml`
  - `proxmox_vm_info`（読み取り専用）で現在の設定を取得し、フィルタ`config_drift`で違う項目だけを取り出す
  - 違いがあれば、その項目だけを`PUT /nodes/<node>/<type>/<vmid>/config`で更新する
  - 上記の理由から、`proxmox_kvm`と`proxmox`は使っていない
- 結果
  - `--check --diff`：作成時の8ゲストとも差分なし（`changed=0`）。801〜803を外したあとの5ゲストでも`changed=0`
  - わざと違う定義（mcのmemory）を渡したcheck modeでは、差分を検出し、更新はスキップされた
  - 本実行：`changed=0`。ゲストの設定ファイルのハッシュも変わらなかった

### 気づいたこと

- LXC 801〜803（llama-rpc、停止中）は2026-10-09にユーザーの指示で削除した。801の固定IP（192.168.1.90）がMetalLBのプールと重なっていた問題も、これでなくなった。削除前のvzdumpも、ユーザーの指示で各ノードのローカルと`pc-backups`の両方から削除した（使わないため）
- VM 101 dtvに、未使用のディスク（`unused0: vm-101-disk-0`、`unused1: vm-101-disk-2`、各4MB）が残っている。2026-10-09の片付けで削除した（中身は空だった）

## 6-4 ゲストの内部（完了）

| ゲスト | 接続方法 | 内容 |
|---|---|---|
| 103 ap | Tailscale SSHのみ（LANの22番は閉じている） | hostapd、netplan、br0 |
| 106 mc | Tailscale SSHのみ（LANの22番は閉じている。tailnetの22番はTailscale SSHが受ける） | ゲームサーバのOS |
| 500 discordbots | `pct exec 500`（開発用LXC、HA対象外） | 開発環境。本番のpricetrackerはk8sに移した |

- Tailscale SSHは、ACLが`check`モードで、ブラウザでの承認がないと入れない。pve-1から非対話で試すと、承認待ちのまま止まる
- 進め方：**tailnetのACLで、apとmcへのroot SSHを`accept`（承認不要）にする**（2026-10-09決定）

### Tailscaleの管理画面での作業（ユーザー）

1. Access controls（ポリシーファイル）に次を追加する。`tagOwners`と`ssh`がすでにある場合は、その中に足す。既存の`check`のルールは残す

   ```jsonc
   "tagOwners": {
     "tag:iac-guest": ["autogroup:admin"],
   },
   "ssh": [
     // IaC（Ansible）用：自分の端末（pve-1 を含む）から ap と mc へ、root で承認なしに入れる
     {
       "action": "accept",
       "src":    ["autogroup:member"],
       "dst":    ["tag:iac-guest"],
       "users":  ["root"],
     },
     // root 以外は従来どおり承認あり
     {
       "action": "check",
       "src":    ["autogroup:member"],
       "dst":    ["tag:iac-guest"],
       "users":  ["autogroup:nonroot"],
     },
   ],
   ```

   - ACLに`acls`/`grants`の制限がある場合は、`autogroup:member`から`tag:iac-guest`への`tcp:22`も許可する（既定の「全許可」なら不要）
2. Machinesで`ap`と`mc`を開き、「Edit ACL tags」から`tag:iac-guest`を付ける
   - タグを付けると、所有者がユーザーからタグに変わり、**鍵の有効期限も無効になる**。apは2026-09-09に鍵の期限切れで止まったことがあるので、その対策にもなる
   - `autogroup:self`を対象にした既存のSSHルールは、タグ付きの端末には適用されなくなる。上の2つのルールで代わりに入れるようにしている

### 決めたこと

- 厳密に「pve-1からだけ」にするには、pve-1にもタグを付けて`src`にする必要がある
- ただ、pve-1にタグを付けると、所有者が変わり、ユーザーからpve-1へのTailscale SSHのルールが適用されなくなるおそれがある。pve-1はこの作業を進めているホストなので避けた
- その代わり、`accept`の対象をapとmcのrootだけに絞った

### 結果（2026-10-09）

- ユーザーがACLを追加し、apとmcに`tag:iac-guest`を付けた。どちらも鍵の有効期限が無効になり、pve-1から通常のsshで承認なしに入れることを確認した
- インベントリに`guests`グループ（ap、mc。tailnetのIP）を追加した
- `playbooks/collect-guests-internal.yml`：管理対象のファイルを`collected/`に回収する（読み取りのみ）
- `playbooks/guests-internal.yml`
  - `roles/host_files`：`host_vars/<host>/host_files.yml`の一覧（パス、所有者、権限、変更時のhandler）に従って、`ansible/host_files/<host>/`のファイルを配る
    - Wi-Fiのパスフレーズ（`sae_password`、3つの設定で同じ値）は`host_vars/ap/wifi.sops.yaml`。テンプレートのタスクはdiffを出さない
    - ネットワーク（netplan）を変えたときのhandlerは`netplan generate`まで。反映は実機のそばで手で行う
  - Minecraftサーバ自体の設定（`server.properties`、`user_jvm_args.txt`、`minecraft.service`）は、2026-10-09にユーザーの指示で管理対象から外した。mcで管理するのはOSの設定（netplan、grub）だけ
- 対象
  - ap：hostapdの設定3つとsystemdの上書き2つ、netplan、networkdの3ファイル（MLD snoopingの無効化を含む）、modprobe 4つ、sysctl、grub、wifi-exporter、wifi-watchdog（service/timer/スクリプト）、metrics.sh、vpnserver.service（unitのファイルだけ。無効のまま）
  - mc：netplan、grub
  - 対象外：CT500（開発環境）、CT903（旧NetBox。2026-10-09に削除）
- `--check --diff`：ap、mcとも`changed=0`

### 気づいたこと

- apのhostapdの設定（パスフレーズを含む）は`644`で、誰でも読めた。2026-10-09に`600`へ絞り、`host_files.yml`も合わせた。権限だけを先に直接変えたので、handlerによるhostapdの再起動は起きていない
- apに`.bak`ファイルが6つ残っている（`/etc/hostapd/*.bak`、`/etc/modprobe.d/*.bak-20260908-184702`、`/usr/local/bin/metrics.sh.bak*`）
- mcのワールド（8.9GB）は、R2へのバックアップの対象外。vzdump（`pc-backups`、3日ごと）とCephのレプリカだけで守られている

## Phase 6の完了条件

- [x] 全ゲストで`--check --diff`が`changed=0`（`guests.yml`：5台、`guests-internal.yml`：ap、mc（OSの設定のみ））
- [x] パススルーを使うVMで`hostpci`が維持されることを確認した（テストVMで検証）
- [x] ゲームサーバのHA設定の管理方法が決まり、文書化されている（`playbooks/ha.yml`）
