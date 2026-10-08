# Phase 0 実施記録（2026-10-09）

## 0-1. 現状の確認

| 確認項目 | 結果 | 後のフェーズへの影響 |
|---|---|---|
| PVE | 9.2.20（kernel 7.0.14-19-pve）、3ノードとも同じ | HA ruleとbpgのHA対応マイグレーションを使える |
| Talos | v1.14.1（3ノード）。手元の`talosctl`は v1.13.6 で古い | Phase 3の`talos_version`は v1.14.1。作業前に`talosctl`を v1.14.x に上げる |
| Kubernetes | v1.36.2 | Phase 3の`kubernetes_version` |
| `secrets.yaml` | `/root/talos-cluster/_out/secrets.yaml` にある。稼働中の設定とcluster id/secret、各CA、token、secretboxがすべて一致することを確認済み | Phase 3でそのままimportできる |
| Talos VMのISO | 3台とも`ide2`に`talos-v1.13.6-qemu-guest-agent-amd64.iso`がつながったまま | Phase 4のimportで差分にならないよう、HCLに書くか事前に外す |
| CNPG | operator 1.30.0（chart cloudnative-pg 0.29.0）、PostgreSQL 18.4、Cluster `monitoring/grafana-db` 2 instances、backup設定なし。cert-managerは未導入 | Barman Cloud Pluginを使う。cert-managerが要るなら先に入れる |

### Helm release

| release | ns | chart | app |
|---|---|---|---|
| cnpg | cnpg-system | cloudnative-pg-0.29.0 | 1.30.0 |
| kube-prometheus-stack | monitoring | kube-prometheus-stack-87.17.0（rev 10） | v0.92.1 |
| metallb | metallb-system | metallb-0.16.1 | v0.16.1 |
| tailscale-operator | tailscale | tailscale-operator-1.98.9 | v1.98.9 |

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

- **vzdumpの定期ジョブは存在しない**（`/etc/pve/jobs.cfg`がない）。PBSもない。
- バックアップ可能なストレージは各ノードの`local`（ルートLV上の`/var/lib/vz`、94GB）だけ。全損時には残らない。
- `storage.cfg`に壊れた定義が2つある。
  - `local-nvme`：`vg_nvme`が存在しない。このせいで`qm destroy --destroy-unreferenced-disks`が失敗する。
  - `data`：存在しないノード`pve`に限定されている。`/etc/pve/nodes/pve/`も空のまま残っている。

### ゲストとHA

| ID | 名前 | ノード | 状態 | ディスク | 備考 |
|---|---|---|---|---|---|
| 101 | dtv | pve-2 | running | local-lvm 128G（実使用約93G） | `hostpci`（780M iGPU、romfile） |
| 103 | ap | pve-1 | running | local-lvm 32G | `hostpci`×3 |
| 106 | mc | pve-1 | running | ceph-pool 64G | ゲームサーバ。HA |
| 201〜203 | talos-cp-1〜3 | pve-1/2/3 | running | ceph-pool 32G | HA対象外 |
| 500 | discordbots | pve-2 | running | ceph-pool 16G | LXC。HA。→ k8sへ移行予定 |
| 801〜803 | llama-rpc-1〜3 | 各ノード | stopped | local-lvm 24G | LXC |
| 903 | netbox | pve-3 | running | ceph-pool 32G | LXC。HA。NetBox v4.3.2。→ k8sへ移行予定 |

- VM 105（ai）は2026-10-09に削除した（ユーザー指示。GPUは取り外し済みだった）。
- HAリソースは`ct:500`、`ct:903`、`vm:106`の3つ。HA ruleはまだない。手順書の前提（HAはゲームサーバだけ）に合わせるため、500と903はk8sに移してHAから外す。

## 0-2. バックアップ

保存先は`pve-1:/root/backups/iac-phase0-2026-10-09/`（root以外は読めない）。

- [x] etcdのスナップショット：`talos/etcd-2026-10-09.db`（revision 26896766）
- [x] Talosのマシン設定：`talos/machineconfig-192.168.1.8{2,3,4}.yaml`。構築時の`_out/`と`patch-*.yaml`も同じ場所に置いた
- [x] CNPGの論理ダンプ：`cnpg/grafana-db-pg_dumpall-2026-10-09.sql`（5.9MB）
- [x] 各PVEホストの設定：`hosts/pve-{1,2,3}-etc.tgz`。`/etc/network`、`/etc/frr`、`/etc/sysctl.d`、`/etc/systemd/system`、udev、modprobe、`/usr/local/bin/*.sh`（`thunderbolt-irq-affinity.sh`を含む）。パッケージ一覧は`hosts/pve-*-packages.txt`
- [x] `/etc/pve`全体：`etc-pve-2026-10-09.tgz`
- [ ] 全ゲストのvzdump：一部だけ取得済み。各ノードの`/var/lib/vz/dump/`にある

| ゲスト | アーカイブ |
|---|---|
| 103 ap | 9.8GB |
| 106 mc | 13.4GB |
| 801 llama-rpc-1 | 21.4GB |
| 500 discordbots | 1.9GB |
| 802 llama-rpc-2 | 21.1GB |
| 803 llama-rpc-3 | 14.5GB |
| 903 netbox | 0.9GB |
| **未取得**：101 dtv、201〜203 Talos | 容量不足。見積もりは101が80〜93GB（録画データは圧縮が効かない想定）、Talos 3台で30〜50GB、合計110〜140GB |

## 0-3〜0-6

- リポジトリ：https://github.com/TomayGo/homelab （private）
- deploy key：「argocd (read-only)」として登録済み。秘密鍵はArgo CDのリポジトリSecretとしてSOPSで暗号化し、`k8s/bootstrap/repo-homelab.enc.yaml`に置いた。Phase 1で`sops -d … | kubectl apply -f -`する。平文の元ファイルは`pve-1:~/.config/homelab/argocd-deploy-key`
- age：公開鍵は`age16jr9chq7kfpyg9da9gc0njmtqs7sgmrxmt99wlr3q7efg59xg9mqlq57rz`。秘密鍵は`pve-1:~/.config/sops/age/keys.txt`
- OpenTofu：v1.13.1。encryptionブロックで`var.state_passphrase`を参照できることを確認した（未確認事項#9は解決）。パスフレーズは`pve-1:~/.config/homelab/tofu-state-passphrase`（40文字）
- PVE APIのユーザーとtoken
  - ユーザー`iac-tofu@pve`、`iac-ansible@pve`にロール`IaC`を`/`で付与した
  - tokenはどちらも`privsep 0`
  - 権限はbpgのドキュメントの例をそのまま使った。PVE 9.2の`Administrator`の全47権限と同じなので、tokenが漏れることはroot権限が漏れることと同じ
  - tokenはSOPSで暗号化して保存した：`tofu/proxmox/proxmox-token.enc.yaml`、`ansible/group_vars/all/proxmox.sops.yaml`
- 導入したツール：sops 3.13.3、OpenTofu 1.13.1、age 1.2.1、jq、gh 2.102.0

## 残っている作業（ユーザー）

- [ ] ageの秘密鍵とOpenTofuのパスフレーズをパスワードマネージャに保管する
- [ ] 101とTalos VMのvzdumpをどうするか決める
