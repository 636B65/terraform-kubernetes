locals {
  vm_ids = { for i, name in sort(keys(local.vms)) : name => var.vm_id_start + i }
}

# The Ubuntu 26.04 cloud image is downloaded once to the node.
# SHA256SUMS published next to the image, used when ubuntu_image_sha256 is not
# set, to look up the checksum the node verifies the download against.
data "http" "ubuntu_sha256sums" {
  count = var.ubuntu_image_file_id == null && var.ubuntu_image_sha256 == null && var.verify_ubuntu_image ? 1 : 0

  url = replace(var.ubuntu_image_url, "//[^/]*$/", "/SHA256SUMS")

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "Could not read SHA256SUMS next to ubuntu_image_url (HTTP ${self.status_code}). Set ubuntu_image_sha256, or verify_ubuntu_image = false."
    }
  }
}

locals {
  ubuntu_image_name = regex("[^/]*$", var.ubuntu_image_url)

  # Expected SHA256 of the image: given, looked up in SHA256SUMS, or none.
  ubuntu_image_sha256 = (
    var.ubuntu_image_sha256 != null ? lower(var.ubuntu_image_sha256) :
    length(data.http.ubuntu_sha256sums) == 0 ? null :
    try(
      regex("(?m)^([0-9a-f]{64}) [ *]${replace(local.ubuntu_image_name, ".", "\\.")}$", data.http.ubuntu_sha256sums[0].response_body)[0],
      null,
    )
  )
}

resource "proxmox_virtual_environment_download_file" "ubuntu" {
  count = var.ubuntu_image_file_id == null ? 1 : 0

  # The node verifies the downloaded image against this checksum.
  checksum           = local.ubuntu_image_sha256
  checksum_algorithm = local.ubuntu_image_sha256 == null ? null : "sha256"

  node_name    = var.proxmox_node
  datastore_id = var.image_datastore
  content_type = "iso"
  file_name    = "ubuntu-26.04-server-cloudimg-amd64.img"
  url          = var.ubuntu_image_url
  overwrite    = false

  lifecycle {
    precondition {
      condition     = !var.verify_ubuntu_image || local.ubuntu_image_sha256 != null
      error_message = "No SHA256 for ${local.ubuntu_image_name} in SHA256SUMS. Set ubuntu_image_sha256, or verify_ubuntu_image = false."
    }
  }
}

# Keeps the image of deployments made before ubuntu_image_file_id existed.
moved {
  from = proxmox_virtual_environment_download_file.ubuntu
  to   = proxmox_virtual_environment_download_file.ubuntu[0]
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
    file_id      = coalesce(var.ubuntu_image_file_id, one(proxmox_virtual_environment_download_file.ubuntu[*].id))
    interface    = "scsi0"
    size         = each.value.disk_gb
    discard      = "on"
    iothread     = true
    ssd          = true
  }

  scsi_hardware = "virtio-scsi-single"

  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    vlan_id     = var.vlan_id
    mac_address = each.value.macs == null ? null : upper(each.value.macs[0])
  }

  dynamic "network_device" {
    for_each = each.value.macs == null ? [] : [each.value.macs[1]]
    content {
      bridge      = var.secondary_bridge
      model       = "virtio"
      vlan_id     = var.secondary_vlan_id
      mac_address = upper(network_device.value)
    }
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

      dynamic "ipv6" {
        for_each = each.value.ipv6 == null ? [] : [each.value.ipv6]
        content {
          address = "${ipv6.value}/${var.ipv6_prefix_length}"
          gateway = var.ipv6_gateway
        }
      }
    }

    # The second ip_config belongs to the second network_device.
    dynamic "ip_config" {
      for_each = each.value.secondary_ip == null ? [] : [each.value.secondary_ip]
      content {
        ipv4 {
          address = "${ip_config.value}/${var.secondary_prefix_length}"
        }
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

    precondition {
      condition     = each.value.secondary_ip == null || var.secondary_bridge != null
      error_message = "VMs with a secondary_ip need secondary_bridge."
    }
  }
}
