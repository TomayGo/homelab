# Phase 5 実施記録（2026-10-09完了）

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
| thunderbolt_irq | `thunderbolt-irq-affinity.sh`（PCIのバス番号に依存しない。データ用の割り込みを最大60秒待ち、4つ固定できなければ失敗する）、unit | 再実行 |
| node_exporter | バイナリ（v1.12.1。バージョンが違うときだけ入れ直す）、unit | 再起動 |
| frr_exporter | バイナリ（v1.12.0）、unit | 再起動 |
| pve_exporter | `/opt/pve-exporter`のvenv（prometheus-pve-exporter 3.10.1）、`pve.yml`（トークンはSOPS）、unit | 再起動 |

exporterのバージョンは、2026-10-09にRenovateのPRで更新したあとの値（取り込んだ時点では1.11.1、1.11.0、3.9.0）。

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

## 本適用（2026-10-09、ユーザー承認後。pve-3 → pve-2 → pve-1の順）

### 適用前に見つかった問題

- **IRQの固定が、pve-2とpve-3で知らないうちに失敗していた**。どちらも9月28日の起動以来「pinned 0/4」で、データ用の割り込みが全CPUに散っていた（pve-1は4/4）
  - pve-3：スクリプトがNHIのPCIバスを`ca`と決め打ちしていたが、8月にeGPUを外したあとに`c8`へ変わっていた
  - pve-2：バスは合っていたが、データ用の割り込み（vector 2、3）はThunderboltのネットワークが上がってから登録される。それより前に5秒の待ちが終わっていた
  - 対策：バス番号を使わずに、NHIの機能番号（`.5`、`.6`）とvector番号で照合するようにした。データ用の割り込みが4つ現れるまで最大60秒待ち、4つ固定できなければ終了コード1で終わる（手順書5-3の修正を含む。ブランチ`phase5-irq-exit`は削除した）
- **pve-3の2つ目のNIC（`nic1`、PCI `03:00.0`のIntel I226）が、vfio-pciに取られたままになっていた**
  - eGPUを外したあと、PCIのバス番号が詰まり、`03:00`がGPUではなくこのNICを指すようになった
  - 9月28日のローリングアップグレードの後片付けでVM105（`hostpci0: 0000:03:00`）が起動され、そのときにNICがVMへ渡された
  - そのため、pve-3のbond0は9月28日から`nic0`の1本だけで動いていた
  - これが原因で、pve-3の最初の適用では`ifreload -a`が「bond0: nic1が存在しない」で失敗した
  - 対処（ユーザー承認後）：VM105（2026-10-09に削除済み）以外に`03:00`を参照するものがないことを確認し、vfio-pciから外してigcに戻した。`ifreload -a`でbond0に戻した（スクリプトは`pve-3:/root/rebind-nic1.sh`、`systemd-run`で実行）

### 結果

| ホスト | 適用した変更 | 適用後 |
|---|---|---|
| pve-3 | interfacesの書式、IRQスクリプト。nic1をigcに戻した | `changed=0`、IRQ 4/4、bondのNIC 2本ともup |
| pve-2 | interfacesの書式、IRQスクリプト | `changed=0`、IRQ 4/4 |
| pve-1 | IRQスクリプトだけ（interfacesはもともと一致） | `changed=0`、IRQ 4/4 |

- 各ホストの適用後に、OSPFの隣接（2つともFull）、table 100の経路、メッシュのping、`ceph -s`（HEALTH_OK）、k8sのノード（3つともReady）、PVEクラスタのquorumを確認した
- 最終の`ansible-playbook playbooks/pve.yml --check --diff`は、3台とも`changed=0`

### 教訓

- `hostpci`をPCIアドレスで指定していると、ハードウェアを外してバス番号が詰まったときに、意図しない別のデバイスをVMに渡してしまうことがある。デバイスを外したら、そのデバイスを渡していたVMの`hostpci`をすぐに消すか、VMごと消す

## 気づいたこと（提案）

- `/etc/prometheus/pve.yml`はパーミッションが`644`で、誰でもトークンを読めた。2026-10-09に`600`へ絞り、roleの定義も合わせた（exporterはrootで動くので読める）

## Phase 5の完了条件

- [x] 3台とも`--check --diff`で`changed=0`
- [x] 管理対象外の項目（`/etc/pve`、Ceph、クラスタ参加、アップグレード）の手順が書かれている（`docs/manual-ops.md`）
