# Phase 3 実施記録（2026-10-09、apply前で停止中）

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

## 残り（要確認）

- [ ] `tofu apply`（secretsのimportと、3ノードへの`no_reboot`適用。dry-runで差分がないことは確認済み）
- [ ] apply後に`tofu plan`が`No changes`になることを確認する
- [ ] 暗号化された`terraform.tfstate`をコミットする
- [ ] 平文の`tofu/talos/secrets.yaml`を削除する（元は`/root/talos-cluster/_out/`にもある）
- [ ] 各ノードで`talosctl health`を確認する
