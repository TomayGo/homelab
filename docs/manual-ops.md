# コードで管理しないものの手順

手順書2章の「管理対象外」の項目は、手作業のまま残す。ここにはその手順だけを書く。

## /etc/pve（pmxcfs）

- `/etc/pve`はpmxcfsがクラスタ全体で同期している。Ansibleやスクリプトで直接書き換えない
- ゲストの設定（`nodes/*/qemu-server/*.conf`、`nodes/*/lxc/*.conf`）は、変えたら次のplaybookを実行して`ansible/guest-configs/`にコミットする（記録用）

  ```sh
  cd ansible && ansible-playbook playbooks/collect-guests.yml </dev/null >/tmp/collect.log 2>&1
  ```

- 丸ごとのバックアップは`tar czf etc-pve-$(date +%F).tgz -C / etc/pve`で取る（`priv/`に鍵があるので、置き場所の権限に注意）
- `storage.cfg`の使えない定義（`local-nvme`、`data`）と、存在しないノードの`/etc/pve/nodes/pve/`は、2026-10-09に削除した。削除前のものは`pve-1:/root/backups/cleanup-2026-10-09/`にある

### vzdumpの定期ジョブ

`/etc/pve/jobs.cfg`のジョブ`backup-every3d`（2026-10-09に作成）。全損したら、`pc-backups`を追加してから同じ内容で作り直す。

```sh
pvesh create /cluster/backup --id backup-every3d --schedule '*-*-1/3 10:00' \
  --storage pc-backups --vmid 101,103,106,500 --mode snapshot --compress zstd \
  --prune-backups keep-last=3 --notes-template '{{guestname}}' \
  --comment 'ap/mc/dtv/discordbots, every 3 days, keep 3'
```

- 対象：101 dtv、103 ap、106 mc、500 discordbots。どれもRepoからは戻せない（ドライバのビルド、SoftEther VPNとZeroTierの状態、ワールドや録画のデータなど）
- 対象外：Talos VM（201〜203）。OpenTofuとArgo CDで作り直せるうえ、PVCはVMのディスクではないのでvzdumpに入らない。CT903（旧NetBox）は2026-10-09に削除した
- 日付が1、4、7、…、31日の10時に取る。31日のある月は、31日と翌月1日が続けて実行される
- CIFSへのvzdumpは毎回フルバックアップになる（差分を取るにはPBSが要る）。1回約60GBで、3世代で約180GB
- 保存先はWindowsのPCなので、10時にPCが起きていないと失敗する
- `keep-last=3`は、手で取ったバックアップも数に入れて消す。2026-10-09に手で取った分も、3回目の実行後に消える

## Ceph（pveceph）

- 構成の変更は、`pveceph`かPVEのGUIで行う。ceph.confやCRUSHマップを直接書き換えない
- 状態の確認：`ceph -s`、`ceph osd tree`、`ceph df`
- ノードを止める前に`ceph osd set noout`、戻したら`ceph osd unset noout`を実行する（pvectlが自動で行う）
- USB4メッシュ上でレプリケーションが詰まった事例がある（2026-07-22）。症状は`journalctl -u ceph-osd@N`のslow opsと、特定のOSDの組。詳しくは`/root/k8s-cluster-setup.md`

## PVEクラスタへの参加

- 新しいノードは、`pvecm add <既存ノードのLAN IP>`で参加させる。corosyncのリングは192.168.1.x（`pvecm status`）
- 参加したら、次の順に進める
  1. Ansibleのインベントリ（`ansible/inventory/hosts.yml`）と`host_vars/<ノード>.yml`を追加する
  2. `ansible-playbook playbooks/pve.yml --limit <ノード> --check --diff`を確認してから本適用する
  3. `pveceph install`と`pveceph mon create`／`pveceph osd create`でCephに入れる
- ノードどうしのSSHは、LANのIPを使う（MagicDNS名はTailscale SSHに横取りされ、対話の認証で止まる）

## PVEとカーネルのアップグレード

- `pvectl upgrade node <n>`か`pvectl rolling-upgrade`を使う（`/root/pvectl-design.md` 10章）
  - 処理の流れ：HAの退避 → k8sのdrain → `apt full-upgrade` → ホストの再起動 → 復旧の確認
  - Talosのアップグレードも同じ再起動の中で行える（`--talos-version`）
- `apt upgrade`ではなく`full-upgrade`を使う（PVEの要件）
- アップグレード中や、ノードが落ちている間は、`tofu apply`とAnsibleの本適用を行わない（手順書8章）
- Talosを上げたら、`tofu/talos/patches/common.yaml`の`machine.install.image`のタグを合わせるかどうかを判断する。pvectlは設定を書き換えずに、タグを差し替えたinstallerを使う

## 手で管理しているパススルー

- `hostpci`（`101 dtv`、`103 ap`）と、`/etc/modprobe.d/vfio.conf`、`/etc/modules-load.d/vfio.conf`（pve-2、pve-3）は、Ansibleでは触らない
- dtvのiGPUは、ACPI VFCTから取り出したVBIOSを`romfile`として渡している

### RTL-SDR（LXC 104 sdr）

JR在来線デジタル列車無線の受信用。RTL-SDR Blog V4L（USB `0bda:2838`）をpve-2に挿し、pve-2上のLXC 104がrtl_tcpを動かす。k8sの`jr-radio`（`k8s/apps/jr-radio/`、http://192.168.1.94/）が、そこへ接続する。

- pve-2に挿す理由：pve-1のUSB-Aポートは、すべてap（VM 103）に渡したコントローラー（c6:00.3/.4）につながっている。pve-1自身のコントローラー（c8:00.3/.4）はUSB4のポートで、TBメッシュに使っている。pve-1に挿すと、apの中でDVBドライバに掴まれる（2026-10-17に確認）
- LXC 104のLAN IPは192.168.1.86（固定、MAC `BC:24:11:86:21:17`）。HGWでもこの組み合わせを予約する。jr-radioはIPアドレスでしか接続先を受け付けない
- ホスト側（ブラックリストとudevルール）と、LXCの中（rtl-sdr-blogのビルド、rtl_tcp、前段の中継、nftables）は`ansible/playbooks/sdr.yml`が扱う。ドングルを挿すホストは、インベントリの`sdr_usb_hosts`に書く
- rtl_tcpは`127.0.0.1:1241`で待つ。外向きの`192.168.1.86:1240`は中継（`rtl_tcp_relay.py`）が受ける。rtl_tcpは、前のクライアントの後始末が済むまで次の接続をacceptしない。切断の直後につなぎ直すと、ヘッダーが届くまで3秒を超えることがあり、jr-radioはヘッダーを3秒しか待たない。中継が前回のヘッダーをすぐ返すことで、これを避けている（中継なしでは10回中1回失敗、中継ありでは20回中20回成功）
- LXCの設定のうち、次の2行はAPIトークンでは書けないので、手で足す。`/etc/pve/lxc/104.conf`の末尾に追記してから、`pct reboot 104`を実行する

  ```
  lxc.cgroup2.devices.allow: c 189:* rwm
  lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir
  ```

  `/dev/bus/usb`をまるごとbindするので、挿し直してデバイス番号が変わっても、LXCの設定は変えなくてよい
- ドングルを別のホストに移すときは、次の順に進める
  1. `sdr_usb_hosts`を書き換えて、playbookを流す
  2. ドライバがすでに掴んでいたら`modprobe -r rtl2832_sdr dvb_usb_rtl28xxu rtl2832`で外す
  3. `pct migrate 104 <ホスト> --restart`で移す（rootfsはceph-poolなので数秒で終わる）
  4. 元のホストの`/etc/modprobe.d/blacklist-rtl28xxu.conf`と`/etc/udev/rules.d/60-rtl-sdr-lxc.rules`を消す
- 確認：LXCの中で`systemctl stop rtl_tcp && rtl_test -t`を実行し、「RTL-SDR Blog V4 Lite Detected」が出ること。終わったら`systemctl start rtl_tcp`を実行する
- Debianの`librtlsdr`/`rtl-sdr`パッケージはV4Lに対応していない（信号が来ない）。入れない
- rtl_tcpには認証がなく、同時に1クライアントしかつながらない。LXCのnftablesで、k8sノード（.82〜.84）とpve-1以外からの接続を落としている（受信内容を外に出さないため。電波法59条）

## ceph-csi-operatorのアップグレード

- Renovateの対象外にしている。イメージのタグだけを上げると、install.yamlに含まれるCRDと食い違うため
- 手順
  1. リリースタグ（`main`ではない）のinstall.yamlを取得して、`k8s/apps/ceph-csi/manifests/operator-install-<版>.yaml`として置く。古いファイルは消し、kustomizationを書き換える
  2. Argo CDの差分で、CRDとDeploymentの変更を確認してからsyncする
- `main`のinstall.yaml（`:latest`イメージ）は使わない。2026-07-20に、これで動かなくなったことがある
