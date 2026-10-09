# コードで管理しないものの手順

手順書2章の「管理対象外」の項目は、手作業のまま残す。ここにはその手順だけを書く。

## /etc/pve（pmxcfs）

- `/etc/pve`はpmxcfsがクラスタ全体で同期している。Ansibleやスクリプトで直接書き換えない
- ゲストの設定（`nodes/*/qemu-server/*.conf`、`nodes/*/lxc/*.conf`）は、変えたら次のplaybookを実行して`ansible/guest-configs/`にコミットする（記録用）

  ```sh
  cd ansible && ansible-playbook playbooks/collect-guests.yml </dev/null >/tmp/collect.log 2>&1
  ```

- 丸ごとのバックアップは`tar czf etc-pve-$(date +%F).tgz -C / etc/pve`で取る（`priv/`に鍵があるので、置き場所の権限に注意）
- `storage.cfg`に使えない定義が2つ残っている（2026-10-09時点。消すかどうかは未決定）
  - `local-nvme`：存在しない`vg_nvme`を参照している。このせいで`qm destroy --destroy-unreferenced-disks 1`が途中で失敗する
  - `data`：存在しないノード`pve`に限定されている
- `/etc/pve/nodes/pve/`（存在しないノード`pve`）も空のまま残っている

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

## ceph-csi-operatorのアップグレード

- Renovateの対象外にしている。イメージのタグだけを上げると、install.yamlに含まれるCRDと食い違うため
- 手順
  1. リリースタグ（`main`ではない）のinstall.yamlを取得して、`k8s/apps/ceph-csi/manifests/operator-install-<版>.yaml`として置く。古いファイルは消し、kustomizationを書き換える
  2. Argo CDの差分で、CRDとDeploymentの変更を確認してからsyncする
- `main`のinstall.yaml（`:latest`イメージ）は使わない。2026-07-20に、これで動かなくなったことがある
