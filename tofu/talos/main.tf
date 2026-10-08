locals {
  cluster_name     = "pve-k8s"
  cluster_endpoint = "https://192.168.1.89:6443"

  # 設定の生成に使う契約バージョン。稼働中は Talos v1.14.1 だが、設定は v1.13 の talosctl で生成したもの。
  # v1.14 の契約で生成すると新しい複数ドキュメント形式になり、現行と大きく食い違う（docs/phase3.md）
  talos_contract     = "v1.13.6"
  kubernetes_version = "1.36.2"

  nodes = {
    talos-cp-1 = { ip = "192.168.1.82" }
    talos-cp-2 = { ip = "192.168.1.83" }
    talos-cp-3 = { ip = "192.168.1.84" }
  }
}

# 既存クラスタの secrets を取り込む（作り直さない）
resource "talos_machine_secrets" "this" {
  talos_version = local.talos_contract

  lifecycle {
    # import 直後の state では talos_version が "v1.3" になる。この差を更新として扱うと
    # provider が secrets を全部作り直す（CA が変わってクラスタが壊れる）ので、絶対に追従させない
    ignore_changes  = [talos_version]
    prevent_destroy = true
  }
}

import {
  to = talos_machine_secrets.this
  id = "./secrets.yaml"
}

data "talos_machine_configuration" "cp" {
  for_each = local.nodes

  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = local.talos_contract
  kubernetes_version = local.kubernetes_version
  docs               = false
  examples           = false

  config_patches = [
    file("${path.module}/patches/common.yaml"),
    file("${path.module}/patches/${each.key}.yaml"),
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = local.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [for n in local.nodes : n.ip]
  nodes                = [for n in local.nodes : n.ip]
}

# bootstrap 系のリソースは書かない（既存クラスタは bootstrap 済み）
resource "talos_machine_configuration_apply" "cp" {
  for_each = local.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
  apply_mode                  = "no_reboot"
}

output "machine_configuration" {
  value     = { for k, v in data.talos_machine_configuration.cp : k => v.machine_configuration }
  sensitive = true
}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}
