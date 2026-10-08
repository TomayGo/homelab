# 既存の Talos VM を取り込む（ID は <ノード名>/<VMID>）
import {
  for_each = local.talos_vms
  to       = proxmox_virtual_environment_vm.talos[each.key]
  id       = "${each.value.node}/${each.value.vm_id}"
}
