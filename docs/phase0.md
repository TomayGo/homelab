# Phase 0 実施記録（2026-10-09）

## 0-1. 現状の確認

| 確認項目 | 結果 | 後のフェーズへの影響 |
|---|---|---|
| PVE | 9.2.20（kernel 7.0.14-19-pve）、3ノードとも同じ | HA ruleとbpgのHA対応マイグレーションを使える |
| Talos | v1.14.1（3ノード）。手元の`talosctl`は v1.13.6 で古かった（Phase 3の前にv1.14.1へ更新した） | Phase 3で使う。実際には、`talos_version`（設定生成の契約）をv1.13.6にした（`docs/phase3.md`） |
| Kubernetes | v1.36.2 | Phase 3の`kubernetes_version` |
| `secrets.yaml` | `/root/talos-cluster/_out/secrets.yaml` にある。稼働中の設定とcluster id/secret、各CA、token、secretboxがすべて一致することを確認済み | Phase 3でそのままimportできる |
| Talos VMのISO | 3台とも`ide2`に`talos-v1.13.6-qemu-guest-agent-amd64.iso`がつながったまま | Phase 4では、`cdrom`を`ignore_changes`で管理対象から外して対応した（`docs/phase4.md`） |
| CNPG | operator 1.30.0（chart cloudnative-pg 0.29.0）、PostgreSQL 18.4、Cluster `monitoring/grafana-db` 2 instances、backup設定なし。cert-managerは未導入。operatorは2026-10-09にRenovateで1.30.1へ更新した | Barman Cloud Pluginを使う。cert-managerが必要だったので、Phase 2で先に入れた |

### Helm release

| release | ns | chart | app |
|---|---|---|---|
| cnpg | cnpg-system | cloudnative-pg-0.29.0 | 1.30.0 |
| kube-prometheus-stack | monitoring | kube-prometheus-stack-87.17.0（rev 10） | v0.92.1 |
| metallb | metallb-system | metallb-0.16.1 | v0.16.1 |
| tailscale-operator | tailscale | tailscale-operator-1.98.9 | v1.98.9 |

Phase 0時点の一覧。Phase 1でArgo CDの管理に移し、Helm releaseは削除した。chartのバージョンは、その後Renovateで更新している（`docs/phase1.md`）。

### Helm管理外のリソース（Phase 1でGitに入れる対象）

元のマニフェストの多くは`/root/talos-cluster/`にある。

| 対象 | リソース |
|---|---|
| ceph-csi-operator | `ceph-csi-operator-install-v1.0.4.yaml`一式（CRD、RBAC、Deployment）、CephConnection/ClientProfile `pve-ceph`、Driver `rbd.csi.ceph.com`、StorageClass `ceph-rbd`、Secret `csi-rbd-secret` |
| MetalLB | IPAddressPool `lan-pool`（192.168.1.90-99）、L2Advertisement `lan-l2` |
| Tailscale | Connector `lan-router`（192.168.1.0/24）、ProxyGroup `egress-pg`、Secret `tailscale/operator`（OAuth） |
| monitoring | Cluster `grafana-db`、Deployment/Service `thanos-query`・`thanos-query-lb`、`discord-bridge`（Deployment、ConfigMap、Secret）、ダッシュボードConfigMap 3つ、`cnpg-default-monitoring`、Service `hostapd-external`、PVC（Prometheus 2つ） |
| dns | AGH primary/replica StatefulSet、Service 5つ、`adguardhome-sync`、`adguard-exporter`、Secret 3つ（`agh-seed-config`、`adguardhome-sync-config`、`adguard-exporter-config`）、PVC 4つ |
| ai | `openwebui`（Deployment、PVC、Service 2つ）、`llmjp-proxy`（kustomize）、egress Service `lmstudio`・`strata`、Secret `openwebui` |
| CRD | monitoring.coreos.com（chartの`crds/`から入ったもの。Helmのラベルなし）、csi.ceph.io |

`tailscale`のnamespaceにある`ts-*`のStatefulSet、Service、Secretはoperatorが生成するので、Gitには入れない。

### vzdumpと保存先

- **vzdumpの定期ジョブは存在しない**（`/etc/pve/jobs.cfg`がない）。PBSもない。2026-10-09に、`pc-backups`へ3日ごとのジョブを作った（`docs/manual-ops.md`）
- バックアップ可能なストレージは各ノードの`local`（ルートLV上の`/var/lib/vz`、94GB）だけ。全損時には残らない。
- `storage.cfg`に使えない定義が2つある。
  - `local-nvme`：`vg_nvme`が存在しない。このせいで`qm destroy --destroy-unreferenced-disks`が失敗する。2026-10-09の片付けで削除した。
  - `data`：存在しないノード`pve`に限定されている。`/etc/pve/nodes/pve/`も空のまま残っている。どちらも2026-10-09の片付けで削除した。

### ゲストとHA

| ID | 名前 | ノード | 状態 | ディスク | 備考 |
|---|---|---|---|---|---|
| 101 | dtv | pve-2 | running | local-lvm 128G（実使用約93G） | `hostpci`（780M iGPU、romfile） |
| 103 | ap | pve-1 | running | local-lvm 32G | `hostpci`×3 |
| 106 | mc | pve-1 | running | ceph-pool 64G | ゲームサーバ。HA |
| 201〜203 | talos-cp-1〜3 | pve-1/2/3 | running | ceph-pool 32G | HA対象外 |
| 500 | discordbots | pve-2 | running | ceph-pool 16G | LXC。開発環境としてHA対象外で残した（本番のpricetrackerはk8sへ移行済み） |
| 801〜803 | llama-rpc-1〜3 | 各ノード | stopped | local-lvm 24G | LXC。2026-10-09に削除した |
| 903 | netbox | pve-3 | running | ceph-pool 32G | LXC。NetBox v4.3.2。k8sへ移行済み。2026-10-09の片付けで削除した（vzdumpは`pc-backups`に残してある） |

- VM 105（ai）は2026-10-09に削除した（ユーザー指示。GPUは取り外し済みだった）。
- HAリソースは`ct:500`、`ct:903`、`vm:106`の3つだった。手順書の前提（HAはゲームサーバだけ）に合わせ、2026-10-09に500と903をHAから外した。現在は`vm:106`だけ。HA ruleは、Phase 6で`mc-prefer-pve-1`（pve-1を優先、非strict）を作った。
- CT903 netbox：k8sの`netbox` namespaceに移行した（`k8s/apps/netbox/`）。CTはロールバック用に残していたが、2026-10-09の片付けで削除した。vzdumpは`pc-backups`に残してある。
- CT500 discordbots：本番の`pricetracker`は、2026-10-09にk8sの`pricetracker` namespaceへ移した（`k8s/apps/pricetracker/`）。CTは開発環境としてHA対象外のまま動かす。

## 0-2. バックアップ

保存先は`pve-1:/root/backups/iac-phase0-2026-10-09/`（root以外は読めない）。

- [x] etcdのスナップショット：`talos/etcd-2026-10-09.db`（revision 26896766）
- [x] Talosのマシン設定：`talos/machineconfig-192.168.1.8{2,3,4}.yaml`。構築時の`_out/`と`patch-*.yaml`も同じ場所に置いた
- [x] CNPGの論理ダンプ：`cnpg/grafana-db-pg_dumpall-2026-10-09.sql`（5.9MB）
- [x] 各PVEホストの設定：`hosts/pve-{1,2,3}-etc.tgz`。`/etc/network`、`/etc/frr`、`/etc/sysctl.d`、`/etc/systemd/system`、udev、modprobe、`/usr/local/bin/*.sh`（`thunderbolt-irq-affinity.sh`を含む）。パッケージ一覧は`hosts/pve-*-packages.txt`
- [x] `/etc/pve`全体：`etc-pve-2026-10-09.tgz`
- [x] 全ゲストのvzdump：PVEストレージ`pc-backups`（CIFS、`//desktop-6vkqmqj.ayu-mamba.ts.net/Backup`、`prune-backups keep-all=1`）の`dump/`にそろえた。最初の7件は各ノードの`/var/lib/vz/dump/`に取ってから`pc-backups`へコピーした（ローカルの元ファイルは、2026-10-09の片付けで、`pc-backups`のものと同じサイズであることを確かめてから削除した）

| ゲスト | アーカイブ |
|---|---|
| 103 ap | 9.8GB |
| 106 mc | 13.4GB |
| ~~801 llama-rpc-1~~（2026-10-09にLXCごと削除、vzdumpも削除） | 21.4GB |
| 500 discordbots | 1.9GB |
| ~~802 llama-rpc-2~~（2026-10-09にLXCごと削除、vzdumpも削除） | 21.1GB |
| ~~803 llama-rpc-3~~（2026-10-09にLXCごと削除、vzdumpも削除） | 14.5GB |
| 903 netbox | 0.9GB |
| 101 dtv | 34.4GB（`pc-backups`に直接） |
| 201/202/203 Talos | 11.1GB / 11.7GB / 9.2GB（`pc-backups`に直接） |

## 0-3〜0-6

- リポジトリ：https://github.com/TomayGo/homelab （2026-10-09にpublicにした）
- deploy key：「argocd (read-only)」として登録済み。秘密鍵はArgo CDのリポジトリSecretとしてSOPSで暗号化し、`k8s/bootstrap/repo-homelab.enc.yaml`に置いた。Phase 1で`sops -d … | kubectl apply -f -`する。平文の元ファイルは`pve-1:~/.config/homelab/argocd-deploy-key`
- age：公開鍵は`age16jr9chq7kfpyg9da9gc0njmtqs7sgmrxmt99wlr3q7efg59xg9mqlq57rz`。秘密鍵は`pve-1:~/.config/sops/age/keys.txt`
- OpenTofu：v1.13.1。encryptionブロックで`var.state_passphrase`を参照できることを確認した（未確認事項#9は解決）。パスフレーズは`pve-1:~/.config/homelab/tofu-state-passphrase`（40文字）
- PVE APIのユーザーとtoken
  - ユーザー`iac-tofu@pve`、`iac-ansible@pve`にロール`IaC`を`/`で付与した
  - tokenはどちらも`privsep 0`
  - 権限はbpgのドキュメントの例をそのまま使った。PVE 9.2の`Administrator`の全47権限と同じなので、tokenが漏れればroot権限が漏れたのと同じになる
  - tokenはSOPSで暗号化して保存した：`tofu/proxmox/proxmox-token.enc.yaml`、`ansible/group_vars/all/proxmox.sops.yaml`
- 導入したツール：sops 3.13.3、OpenTofu 1.13.1、age 1.2.1、jq、gh 2.102.0

## 残っている作業（ユーザー）

- [x] ageの秘密鍵とOpenTofuのパスフレーズをパスワードマネージャに保管した（2026-10-09）
