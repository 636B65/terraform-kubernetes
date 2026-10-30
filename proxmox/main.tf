locals {
  vm_ids = { for i, name in sort(keys(local.vms)) : name => var.vm_id_start + i }
}

# The Ubuntu 26.04 cloud image is downloaded once to the node.
resource "proxmox_virtual_environment_download_file" "ubuntu" {
  node_name    = var.proxmox_node
  datastore_id = var.image_datastore
  content_type = "iso"
  file_name    = "ubuntu-26.04-server-cloudimg-amd64.img"
  url          = var.ubuntu_image_url
  overwrite    = false
}

# cloud-init user-data (user, password, SSH) per VM.
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = local.vms

  node_name    = var.proxmox_node
  datastore_id = var.snippets_datastore
  content_type = "snippets"

  source_raw {
    file_name = "${each.key}-user-data.yaml"
    data      = module.cloud_init.user_data[each.key]
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  for_each = local.vms

  name        = each.key
  node_name   = var.proxmox_node
  vm_id       = local.vm_ids[each.key]
  description = "Ubuntu 26.04 - managed by Terraform"
  tags        = ["terraform", "ubuntu"]
  on_boot     = var.start_on_boot
  started     = true

  machine = "q35"
  bios    = "seabios"

  operating_system {
    type = "l26"
  }

  # qemu-guest-agent is installed by cloud-init and reports the IP to Proxmox.
  agent {
    enabled = true
    timeout = "15m"
  }

  cpu {
    cores = each.value.cpu
    type  = var.cpu_type
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.vm_datastore
    file_id      = proxmox_virtual_environment_download_file.ubuntu.id
    interface    = "scsi0"
    size         = each.value.disk_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  scsi_hardware = "virtio-scsi-single"

  network_device {
    bridge  = var.network_bridge
    model   = "virtio"
    vlan_id = var.vlan_id
  }

  # Ubuntu cloud images expect a serial console.
  serial_device {}

  initialization {
    datastore_id = var.vm_datastore

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.ip_prefix_length}"
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
      domain  = var.dns_domain == "" ? null : var.dns_domain
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id
  }

  lifecycle {
    ignore_changes = [disk[0].file_id]
  }
}
