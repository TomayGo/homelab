# Phase 1 実施記録（2026-10-09〜）

## 構成

- Argo CD：chart `argo/argo-cd` 10.10.1（v3.5.4）。初回は`k8s/bootstrap/values.yaml`で`helm install`した。以後はApplication `argocd`で自己管理する
- UI：http://argocd.ayu-mamba.ts.net （tailnetのみ、TLSなし）
- KSOPS：v4.5.1。repo-serverのinitContainerで`ksops install /custom-tools`を実行し、ksopsだけを追加する（kustomizeはArgo CD同梱のものを使う）。age鍵はSecret `argocd/sops-age`
- app-of-apps：ルートは`k8s/bootstrap/root.yaml`。子は`k8s/root/*.yaml`の11個
- 全Applicationの共通設定
  - `syncOptions: ServerSideApply=true`
  - `automated`は付けていない

| Application | 種類 | namespace | release / chart |
|---|---|---|---|
| argocd | Helm + manifests | argocd | argocd / argo-cd 10.10.1 |
| kube-prometheus-stack | Helm + manifests | monitoring | kube-prometheus-stack / 87.17.0 |
| thanos-query | manifests | monitoring | - |
| cloudnative-pg | Helm + manifests | cnpg-system（`grafana-db`はmonitoring） | cnpg / cloudnative-pg 0.29.0 |
| adguard-home | manifests | dns | - |
| netbox | Helm + manifests | netbox | netbox / netbox 8.3.91 |
| pricetracker | manifests | pricetracker | - |
| openwebui | manifests | ai | - |
| metallb | Helm + manifests | metallb-system | metallb / metallb 0.16.1 |
| ceph-csi | manifests（install.yaml v1.0.4） | ceph-csi-operator-system | - |
| tailscale-operator | Helm + manifests | tailscale | tailscale-operator / 1.98.9 |

## 取り込み時に変えたこと

- tailscale-operator
  - valuesにOAuthのclientSecretが平文で書かれていたので、valuesから`oauth`を外した
  - 既存のSecret `operator-oauth`は、SOPS（`manifests/operator-oauth.enc.yaml`）で管理する
  - chartは`oauth.clientId`が書かれているとSecretを生成するので、clientIdも書かない
- Grafanaの管理者パスワード
  - chartは、パスワードを指定しないとき`lookup`で既存のSecretを引き継ぎ、なければ乱数を生成する。Argo CDでは`lookup`が効かないので、描画のたびに値が変わる
  - 対策として`grafana.admin.existingSecret: kube-prometheus-stack-grafana`を指定し、そのSecretをSOPSで管理する
- openwebui
  - `lmstudio`と`strata`の`spec.externalName`は、Tailscale operatorが`placeholder`から書き換える
  - そのため`ignoreDifferences`と`RespectIgnoreDifferences=true`で比較の対象から外した
- Helm管理外のリソース
  - liveを書き出し、uid、resourceVersion、managedFields、last-applied、status、ServiceのclusterIPなどを除いてからGitに置いた
  - 複数行の文字列はブロック形式で出力した
  - ConfigMapのdataがliveとバイト単位で一致することを確認した

## 差分の確認結果（sync前）

- `kubectl diff`（サーバ側のdry-run）：10アプリ中9アプリで差分ゼロ。openwebuiの差分はexternalNameだけ（上記のとおり除外した）
- `argocd app diff`：12個すべてで、差分は`argocd.argoproj.io/tracking-id`注釈の追加だけ。netboxの`netbox-db`には、live側の`annotations: {}`もある
- 注意
  - Helmで作ったリソースには`last-applied`の注釈がない。このため「liveにあってGitにない項目」は差分に出ない
  - Server-Side Applyでは、そうした項目は他の管理者の所有として残る。消されて壊れることはない
- Helmのフック（Job/Pod）は、どのアプリの描画結果にもない

## 未確認事項の結果

- #5 KSOPSとargo-helm：READMEの手順が`mv`から`ksops install [--with-kustomize] <dir>`に変わっていた。上記の構成で、全アプリのKSOPS復号がArgo CD上で動くことを確認した
- #6 複数sourceと`$values`：Argo CD v3.5.4で、手順書の書き方のまま動いた（全Helmアプリで描画できた）
- `kubectl kustomize`には`--enable-exec`がない。ローカルでの確認には、単体のkustomize（v5.8.3）と`/usr/local/bin/ksops`を使う
- `argocd` CLIの`--core`は、kubeconfigのカレントnamespaceが`argocd`である必要がある

## 残り

- [ ] sync（手順書の順。差分は追跡用注釈だけ）
- [ ] Helm release Secretの削除（argocd、kube-prometheus-stack、cnpg、netbox、metallb、tailscale-operator）
- [ ] 数日様子を見てから`automated`（`selfHeal: true`）を有効にする。`prune`は全アプリの取り込み後
- [ ] `argocd-initial-admin-secret`の扱い（ログイン後に削除）
