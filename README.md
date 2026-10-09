# homelab

自宅のProxmox VE 3台（pve-1/2/3）のクラスタと、その上で動かしているTalos LinuxのKubernetesクラスタを、IaC/GitOpsで管理するリポジトリ。

| ディレクトリ | 内容 | ツール |
|---|---|---|
| `k8s/` | Kubernetes上のアプリ | Argo CD + KSOPS |
| `tofu/talos/` | Talosのsecretsとマシン設定 | OpenTofu（siderolabs/talos） |
| `tofu/proxmox/` | TalosのVM | OpenTofu（bpg/proxmox） |
| `ansible/` | PVEホストと、個別に作ったVM・LXC | Ansible |
| `docs/` | 全損時の復旧手順など | - |

## 文書

- [docs/manual-ops.md](docs/manual-ops.md)：コードで管理しないもの（`/etc/pve`、Ceph、クラスタ参加、アップグレード、パススルー）の手順
- [docs/recovery.md](docs/recovery.md)：全損時の復旧手順
- `docs/phase*.md`：移行の各フェーズの記録
