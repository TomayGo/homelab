locals {
  # memory（MiB）はホストごとに違う。pve-1 は ap + mc（HA、12 GiB）で埋まっているので 8 GiB のまま、
  # pve-2 / pve-3 を増やして、どのノードが落ちても残り 2 台に Pod が収まるようにする（2026-10-09）。
  # pve-3 は mc の HA 退避先（ansible/playbooks/ha.yml）なので、mc 12 GiB が入る余地を残して 11 GiB
  talos_vms = {
    talos-cp-1 = { node = "pve-1", vm_id = 201, memory = 8192, mac_lan = "BC:24:11:8F:20:15", mac_mesh = "BC:24:11:0D:3B:71" }
    talos-cp-2 = { node = "pve-2", vm_id = 202, memory = 12288, mac_lan = "BC:24:11:3A:B4:FF", mac_mesh = "BC:24:11:D8:91:1E" }
    talos-cp-3 = { node = "pve-3", vm_id = 203, memory = 11264, mac_lan = "BC:24:11:76:F1:9D", mac_mesh = "BC:24:11:D7:D8:FA" }
  }
}

# Talos の control-plane VM（各 PVE ノードに1台ずつ固定。Proxmox HA の対象外）
resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.talos_vms

  name      = each.key
  node_name = each.value.node
  vm_id     = each.value.vm_id

  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-pci"
  boot_order    = ["scsi0", "ide2"]
  on_boot       = true
  started       = true
  tablet_device = true

  # 手作業でマイグレーションしても再作成させない（migrate=false のまま node_name が変わると作り直しになる）
  migrate = false

  # 再起動が必要な変更は apply を失敗させる
  reboot_after_update = false

  agent {
    enabled = true
  }

  cpu {
    cores   = 4
    sockets = 1
    type    = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = "ceph-pool"
    interface    = "scsi0"
    file_format  = "raw"
    size         = 32
    aio          = "io_uring"
    cache        = "none"
    discard      = "ignore"
    iothread     = false
    ssd          = false
    backup       = true
    replicate    = true
  }

  efi_disk {
    datastore_id      = "ceph-pool"
    file_format       = "raw"
    type              = "4m"
    pre_enrolled_keys = false
  }


  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = each.value.mac_lan
    firewall    = false
  }

  # USB4 メッシュ側（10.10.x.0/28）
  network_device {
    bridge      = "vmbr9"
    model       = "virtio"
    mac_address = each.value.mac_mesh
    firewall    = false
  }

  operating_system {
    type = "l26"
  }

  serial_device {
    device = "socket"
  }

  vga {
    type   = "serial0"
    memory = 16
  }

  # ide2 にはインストール用の ISO（local:iso/talos-v1.13.6-qemu-guest-agent-amd64.iso）がつながっている。
  # import では state に入らず、cdrom ブロックを書くと enabled = false で差分になる（ISO が外れるおそれ）ので管理しない
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [node_name, cdrom]
  }
}
