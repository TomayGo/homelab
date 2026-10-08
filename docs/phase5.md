# Phase 5 実施記録（2026-10-09、本適用前で停止中）

## 構成（`ansible/`）

- ansible-core 2.19.11（Debianパッケージ）。collectionは`ansible/collections/`に入れた（gitignore対象）
  - community.sops 2.5.0、community.proxmox 2.1.0、community.general 13.5.0、ansible.posix 2.2.2
- インベントリは`inventory/hosts.yml`。`inventory/host_vars`と`inventory/group_vars`は、`../host_vars`と`../group_vars`へのシンボリックリンク（手順書の配置に合わせるため）
- SOPSのファイル（`*.sops.yaml`）は、community.sopsのvarsプラグインで読み込む（`ansible.cfg`）
- この環境では、ansibleの標準入出力がノンブロッキングだと起動しない。`</dev/null >log 2>&1`で実行する
- `playbooks/collect-pve.yml`：管理対象のファイルを`collected/<host>/`に回収する（読み取りのみ）
- `playbooks/pve.yml`：本体（`serial: 1`）

| role | 管理する内容 | handler |
|---|---|---|
| pve_network | `/etc/network/interfaces`（テンプレート。ホストごとの値は`host_vars`） | `ifreload -a` |
| frr | `frr.conf`（hostname、router-idをテンプレート化）、`daemons` | reload / restart |
| sysctl | `/etc/sysctl.d/90-usb4-ecmp.conf` | `sysctl --system` |
| thunderbolt_net | udevルール（85、99）、modules-load、`thunderbolt-ecmp.service`と`-setup.sh`、`thunderbolt-net-recover.sh` | udev reload、daemon-reload |
| thunderbolt_irq | `thunderbolt-irq-affinity.sh`（NHIのPCIバスを`tb_nhi_pci_bus`で切り替え）、unit | 再実行 |
| node_exporter | バイナリ（v1.11.1。バージョンが違うときだけ入れ直す）、unit | 再起動 |
| frr_exporter | バイナリ（v1.11.0）、unit | 再起動 |
| pve_exporter | `/opt/pve-exporter`のvenv（prometheus-pve-exporter 3.9.0）、`pve.yml`（トークンはSOPS）、unit | 再起動 |

- unitは3つとも、すでに`Restart=always`になっている（手順書の`Restart=on-failure`より強い設定）
- 管理対象外にしたもの
  - `/etc/modprobe.d/vfio.conf`と`/etc/modules-load.d/vfio.conf`（pve-2、pve-3）：パススルー関係なので、手順書の方針どおり手で管理する
  - `/usr/local/bin/pvectl`：別のリポジトリ（`/root/pvectl`）で管理している
  - `/etc/network/interfaces.d/sdn`：PVEのSDNが生成するファイル
  - `/etc/modprobe.d/zfs.conf`：管理していない

## `--check --diff`の結果

| ホスト | changed | 内容 |
|---|---|---|
| pve-1 | 0 | - |
| pve-2 | 1 | `/etc/network/interfaces`の書式だけ（インデントがスペース、`source`の位置） |
| pve-3 | 1 | `/etc/network/interfaces`の書式だけ（PVEの自動生成ヘッダ、`nic2`/`wlp4s0`/`source`の位置） |

- pve-2、pve-3の差分は、スタンザ単位の比較で**意味的に同一**であることを確認した。違いは書式と順序だけ
- テンプレートはpve-1の書式に合わせた。本適用すると、2台のファイルの書式がそろう
- PVEのGUIでネットワークを編集すると、PVEがこのファイルを書き直す。その場合は、またこの種の差分が出る

## 気づいたこと（提案）

- **`thunderbolt-irq-affinity.sh`は、IRQが1つも見つからなくても終了コード0で終わる**（手順書5-3の修正はまだ入っていない）
  - 修正版はブランチ`phase5-irq-exit`に用意した。本適用すると、3台のスクリプトが変わる
- `/etc/prometheus/pve.yml`はパーミッションが`644`で、誰でもトークンを読める。権限はPVEAuditorだけなので影響は小さいが、`600`にするのがよい（未変更）

## 残り（要確認、実機のそばで）

- [ ] pve-2、pve-3の`interfaces`の書式をそろえる本適用（`--limit pve-2`から1台ずつ。適用後にOSPFの隣接と`ceph -s`を確認する）
- [ ] IRQスクリプトの修正（`phase5-irq-exit`）をマージして適用する
- [ ] 管理対象外の項目（`/etc/pve`、Ceph、クラスタ参加、アップグレード）の手順をREADMEに書く
