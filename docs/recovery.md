# 全損時の復旧手順

手順書9章の具体版。2026-10-09時点の構成をもとにしている。Phase 2（CNPGの外部S3バックアップ）とPhase 3〜4のapplyは、まだ終わっていない。

## 必要なもの

- ageの秘密鍵（パスワードマネージャ）→ `~/.config/sops/age/keys.txt`
- OpenTofuのstate暗号化パスフレーズ（パスワードマネージャ）→ `TF_VAR_state_passphrase`
- GitHubの認証情報（`TomayGo/homelab`をcloneするため）
- vzdump：PVEストレージ`pc-backups`（`//desktop-6vkqmqj.ayu-mamba.ts.net/Backup`）の`dump/`
  - 定期ジョブはまだない。2026-10-09に全ゲスト分を手で取得した

## 手順

| 順序 | 作業 | 使うもの |
|---|---|---|
| 1 | PVE 9をインストールし、LANのIP（.79/.80/.81）とホスト名を設定する。Ansibleでネットワーク、FRR、sysctl、USB4メッシュ、exporterを適用する | `ansible/`（`playbooks/pve.yml`。1台ずつ） |
| 2 | `pvecm create` / `pvecm add`でクラスタを組み、Cephを作り直す。プール`ceph-pool`、`k8s-rbd` | `docs/manual-ops.md` |
| 3 | PVEストレージ`pc-backups`（CIFS）を追加し、一点物のゲスト（103 ap、106 mc、101 dtv、500 discordbotsなど）をvzdumpから戻す。HAは`ansible/playbooks/ha.yml` | vzdump、`ansible/guest-configs/` |
| 4 | Talos VMを作り直す（`prevent_destroy`は、VMが存在しない状態からの作成を妨げない） | `tofu/proxmox/` |
| 5 | Talosの設定を適用し、1台目で`talosctl bootstrap`を手で実行する | `tofu/talos/`（secretsは`secrets.enc.yaml`からも戻せる） |
| 6 | Argo CDを手で入れ、ルートのApplicationを作る（下記） | `k8s/bootstrap/` |
| 7 | Argo CDが全アプリを同期するのを待つ（自動syncが無効なら、手順書の順に手でsyncする） | `k8s/` |
| 8 | CNPG（grafana-db、netbox-db）をS3から`bootstrap.recovery`で戻す | 外部S3（Phase 2の完了後） |

### 6. Argo CDのbootstrap

```sh
kubectl create namespace argocd
kubectl -n argocd create secret generic sops-age --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --version 10.10.1 -f k8s/bootstrap/values.yaml
# リポジトリの認証情報（deploy key）と tailnet の Service。KSOPS が必要なので単体の kustomize と ksops を使う
kustomize build --enable-alpha-plugins --enable-exec k8s/bootstrap/manifests | kubectl apply -f -
kubectl apply -f k8s/bootstrap/root.yaml
```

- syncしたら、Helmのrelease Secret（`owner=helm`）は作らない（`helm install`したargocdのものは消す）
- ceph-csiは、`k8s/apps/ceph-csi/manifests/csi-rbd-secret.enc.yaml`のCephユーザー（`client.k8s`）が新しいCephに存在しないと動かない。手順2で同じ名前のユーザーを作り、鍵をSOPSのファイルに書き戻す

## 失われるもの（受け入れ済み）

- Cephごと失った場合、CNPG以外のPVCは失われる。対象は、Prometheusの履歴、Grafanaの手動の変更分、AGHのクエリログと設定（`agh-seed-config`から初期化される）、Open WebUIの履歴、pricetrackerの登録内容、NetBoxのmedia
- AGHの設定は`agh-seed-config`（SOPS）から初期化されるが、seedより後にGUIで変えた分は戻らない
- Open WebUIとpricetrackerのデータはSQLiteで、CNPGのバックアップ対象ではない（必要ならPhase 2のあとで検討する）
