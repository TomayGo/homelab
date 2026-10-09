# Phase 7 実施記録（2026-10-09、設定のみ。Renovateアプリは未導入）

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
- siderolabs/talosのminor以上の更新は、Dependency Dashboardで承認してから出す（設定生成の契約とあわせて手で上げるため）
- 注意
  - Renovate 44はNode.js 24以上が必要（Debianのnode 20、node 22では動かない）
  - ローカルで試すときは、`renovate.json`をコミットしてから実行する（gitで追跡しているファイルしか見ない）

## 気づいたこと

- **`dns/adguard-exporter`（`ghcr.io/henrywhitaker3/adguard-exporter`）と`dns/adguardhome-sync`（`ghcr.io/bakito/adguardhome-sync`）が`:latest`タグで動いている**
  - ceph-csi-operatorが`:latest`の更新で動かなくなったのと同じ形
  - Renovateは`latest`を更新できないので、バージョンを固定するのがよい（未変更。変更するとArgo CDのsyncが必要）

## 残り（ユーザー）

- [ ] GitHubでRenovateアプリをインストールし、`TomayGo/homelab`を対象にする
- [ ] 最初に来るOnboardingのPRと、Dependency Dashboardを確認する
