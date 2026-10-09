# Phase 3 実施記録（2026-10-09完了）

## 構成（`tofu/talos/`）

- provider：`siderolabs/talos` 0.12.0
- OpenTofu：1.13.1。state と plan は pbkdf2 + aes_gcm で暗号化する
- `talos_machine_secrets.this`：`./secrets.yaml`（gitignore対象）からimportする。SOPSで暗号化したコピーは`secrets.enc.yaml`
- `data.talos_machine_configuration.cp`：3ノード分。パッチは`patches/common.yaml`と`patches/<ノード名>.yaml`
- `talos_machine_configuration_apply.cp`：3ノード分（`apply_mode = "no_reboot"`）
- bootstrap系のリソースは書いていない

## 決めたこと

- **`talos_version`（設定生成の契約）は`v1.13.6`にした**
  - 稼働中のTalosはv1.14.1だが、設定はv1.13のtalosctlで生成されたものに、パッチを当ててきたもの
  - v1.14の契約で生成すると、新しい複数ドキュメント形式（KubeAPIServerConfig、KubeletConfigなど）になり、現行と大きく食い違う
  - 新形式への移行は、別の作業として後で行う
- **`talos_machine_secrets`には`ignore_changes = [talos_version]`と`prevent_destroy`を付けた**
  - importした直後のstateでは、`talos_version`が`"v1.3"`になる
  - そのままではin-placeの更新と判定され、secretsがすべて`known after apply`になる。つまり**CAを含むsecretsが作り直される**plan になった
- `install.image`は、v1.13.6のfactoryイメージ（qemu-guest-agent入り）のままにした。`talosctl upgrade`では設定が書き換わらないため
- HostnameConfigは、gen configが出すもの（`auto: stable`）を`$patch: delete`で消し、ノードごとに`hostname`だけのものを入れ直した

## 差分の確認結果

- `tofu plan`：`1 to import, 3 to add, 0 to change, 0 to destroy`。3つのaddは`talos_machine_configuration_apply`
- planから生成した設定を取り出し、`talosctl apply-config --dry-run`で確認した：**3ノードとも`No changes`**

## apply（2026-10-09、ユーザー承認後）

1. `-target=talos_machine_secrets.this`で、importだけを先に確定した
2. 適用の直前に、3ノードのdry-runをもう一度実行し、`No changes`であることを確認した
3. `talos_machine_configuration_apply`を1ノードずつ`-target`で適用し、ノードごとに`talosctl health`を確認した（3台ともOK。設定に差分がないので、再起動などは起きていない）
4. 出力値（talosconfig）を保存するだけのapplyを行い、`tofu plan`が`No changes`になった
5. 暗号化された`terraform.tfstate`をコミットした
6. 平文の`tofu/talos/secrets.yaml`を削除した。元のファイルは`/root/talos-cluster/_out/secrets.yaml`にある。state を失ったときは、`sops -d secrets.enc.yaml > secrets.yaml`で戻してから再importする

## Phase 3の完了条件

- [x] 全ノードで`apply-config --dry-run`の差分がない
- [x] `tofu plan`が`No changes`
- [x] 暗号化されたstateがGitにコミットされている
