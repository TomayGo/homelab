# homelab

PVE 3ノードクラスタ（pve-1/2/3）と、その上のTalos k8sクラスタのIaC/GitOpsリポジトリ。

| ディレクトリ | 内容 | ツール |
|---|---|---|
| `k8s/` | k8s上のアプリ | Argo CD + KSOPS |
| `tofu/talos/` | Talosのsecretsとマシン設定 | OpenTofu（siderolabs/talos） |
| `tofu/proxmox/` | Talos VM | OpenTofu（bpg/proxmox） |
| `ansible/` | PVEホストと一点物のゲスト | Ansible |
| `docs/` | 全損時の復旧手順など | - |

## 秘密情報

リポジトリの外に置くのは次の3つだけ。すべてパスワードマネージャに保管する。

- ageの秘密鍵（`~/.config/sops/age/keys.txt`）
- OpenTofuのstate暗号化パスフレーズ（`TF_VAR_state_passphrase`）
- GitHubの認証情報

平文のSecretはコミットしない。暗号化するファイル名は `k8s/**/*.enc.yaml`、`ansible/**/*.sops.yaml`、`tofu/**/*.enc.yaml`。

## 文書

- [docs/manual-ops.md](docs/manual-ops.md)：コードで管理しないもの（`/etc/pve`、Ceph、クラスタ参加、アップグレード、パススルー）の手順
- [docs/recovery.md](docs/recovery.md)：全損時の復旧手順
- `docs/phase*.md`：移行の各フェーズの記録
