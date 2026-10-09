# Phase 7 実施記録（2026-10-09完了）

- `renovate.json`を追加した。公式の`renovate-config-validator --strict`で検証済み
- `ansible/requirements.yml`のcollectionを、現在のバージョンに固定した（固定しないとRenovateが更新を出せない）

## 未確認事項#13の結果

Renovate 44.147.0を`--platform=local --dry-run=extract`で実行し、次のとおり検出できることを確認した。

| manager | 対象 | 検出内容 |
|---|---|---|
| argocd | `k8s/root/*.yaml`、`k8s/bootstrap/root.yaml` | 複数sourceのApplicationのHelm chart 6つ（argo-cd、kube-prometheus-stack、cloudnative-pg、metallb、netbox、tailscale-operator） |
| kubernetes | `k8s/apps/*/manifests/*.yaml` | コンテナイメージ（AGH、ceph-csi-operator、thanos、open-webui、valkey、pythonなど） |
| helm-values | `k8s/apps/*/values.yaml`、`k8s/bootstrap/values.yaml` | thanosのsidecar、ksops |
| terraform | `tofu/*/versions.tf` | bpg/proxmox、siderolabs/talos |
| ansible-galaxy | `ansible/requirements.yml` | collection 4つ |
| regex（自作） | `ansible/roles/*/defaults/main.yml` | node_exporter、frr_exporter（GitHub releases）、prometheus-pve-exporter（PyPI） |

- 自リポジトリの`targetRevision: main`と、manifestの`apiVersion`は無効にした
- privateな`ghcr.io/tomaygo/pricetracker`は無効にした（イメージの更新はpricetrackerリポジトリのCIで行う）
- ceph-csi-operatorのイメージは無効にした。install.yaml（CRDを含む）ごと同じバージョンに入れ替える必要があり、タグだけを上げるとCRDと食い違うため（手順は`docs/manual-ops.md`）
- メジャーアップデートは、Dependency Dashboardで承認してからPRを作る
- siderolabs/talosのminor以上の更新は、Dependency Dashboardで承認してから出す（設定生成の契約とあわせて手で上げるため）
- 注意
  - Renovate 44はNode.js 24以上が必要（Debianのnode 20、node 22では動かない）
  - ローカルで試すときは、`renovate.json`をコミットしてから実行する（gitで追跡しているファイルしか見ない）

## 気づいたこと

- **`dns/adguard-exporter`（`ghcr.io/henrywhitaker3/adguard-exporter`）と`dns/adguardhome-sync`（`ghcr.io/bakito/adguardhome-sync`）が`:latest`タグで動いている**
  - ceph-csi-operatorが`:latest`の更新で動かなくなったのと同じ形
  - Renovateは`latest`を更新できないので、バージョンを固定するのがよい（未変更。変更するとArgo CDのsyncが必要）

## Renovateアプリの導入（2026-10-09）

- ユーザーがGitHubにRenovateアプリを入れ、対象を`TomayGo/homelab`だけにした
- Mendの設定で「Silent mode」がオンになっていて、検出はするがPRとDependency Dashboardを作らない状態だった。ユーザーがオフにした
- `renovate.json`がすでにあったので、Onboarding PRは作られなかった。Dependency DashboardはIssue #3
- 最初に届いた11件のPRを、描画した差分と上流のリリースノートで確認した。中身に問題があるものはなかった

### 最初の更新の反映

#12（kube-prometheus-stack v92。のちに#13として作り直し）以外の10件をマージし、アプリごとに順番にsyncした。

| 順 | 対象 | 結果 |
|---|---|---|
| 1 | cloudnative-pg 0.29.1（operator 1.30.1） | CNPGがDBのPodを1台ずつ作り直すあいだ、Argo CDの判定が一時的にDegradedになった（CNPGの通常の動作）。2つのDBとも正常 |
| 2 | kube-prometheus-stack 87.21.0、thanos 0.42.4、discord-bridgeのpython 3.14 | Prometheusが1台ずつ入れ替わった。監視対象はすべてup |
| 3 | llmjp-proxyのpython 3.14 | python 3.14.5で動作。2つのスクリプトは、事前にpython 3.14のコンテナで構文とimportを確認した |
| 4 | AdGuard Home 0.107.79、busybox 1.38 | primaryのStatefulSetだけを先にsyncし（`--resource apps:StatefulSet:dns/agh-primary`）、応答を確かめてからreplicaをsyncした |
| 5 | tailscale-operator 1.102.4 | tailnet用のプロキシがすべて作り直された。tailnetのAGH（primaryとreplica）が同時に止まったのは約20秒 |
| 6 | node_exporter 1.12.1、frr_exporter 1.12.0、pve-exporter 3.10.1 | Ansibleで1台ずつ反映した。exporterのroleがcheck modeで失敗するバグを直した |

- tailnet公開用のプロキシ（Serviceへの注釈で作るもの）は1レプリカで、増やしても別のIPになるため冗長化できない。ProxyGroupの共有IPによる冗長化は、上流の[tailscale/tailscale#17726](https://github.com/tailscale/tailscale/issues/17726)（IPv4だけのクラスタで動かない）がまだ直っていない
- 対策の案として、tailnetのDNSに`192.168.1.92`（3レプリカのlan-router経由で届くLANのVIP）を足す方法がある（未実施）

## 残り

- [x] GitHubでRenovateアプリをインストールし、`TomayGo/homelab`を対象にする
- [x] Dependency Dashboardを確認する
- [ ] #13（kube-prometheus-stack v92。履歴の書き換えで#12が閉じたため、Renovateが作り直した）は、87.21.0の様子を見てから進める。87→92の移行の注意点は確認済みで、今のvaluesは影響を受けない
