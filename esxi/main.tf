locals {
  # Packages cloud-init installs on this platform in addition to extra_packages.
  platform_packages = []

  # Hashing the OVA takes a few seconds, so it is done once, and only when a
  # checksum is set.
  ubuntu_image_verified = (
    var.ubuntu_image_sha256 == null ? true :
    can(regex("^https?://", var.ubuntu_ova)) ? false :
    filesha256(var.ubuntu_ova) == lower(var.ubuntu_image_sha256)
  )
}

resource "esxi_guest" "vm" {
  for_each = local.vms

  guest_name = each.key
  disk_store = var.datastore
  notes      = "Ubuntu 26.04 - managed by Terraform"

  ovf_source = var.ubuntu_ova

  numvcpus       = each.value.cpu
  memsize        = each.value.memory_mb
  boot_disk_size = each.value.disk_gb
  boot_disk_type = "thin"
  power          = "on"

  network_interfaces {
    virtual_network = var.network
    nic_type        = "vmxnet3"
    mac_address     = each.value.macs == null ? null : each.value.macs[0]
  }

  dynamic "network_interfaces" {
    for_each = each.value.macs == null ? [] : [each.value.macs[1]]
    content {
      virtual_network = var.secondary_network
      nic_type        = "vmxnet3"
      mac_address     = network_interfaces.value
    }
  }

  # cloud-init (VMware datasource) reads IP, user, password and SSH from here.
  guestinfo = {
    "metadata"          = base64encode(module.cloud_init.meta_data[each.key])
    "metadata.encoding" = "base64"
    "userdata"          = base64encode(module.cloud_init.user_data[each.key])
    "userdata.encoding" = "base64"
  }

  guest_startup_timeout  = 180
  guest_shutdown_timeout = 30

  lifecycle {
    precondition {
      condition     = each.value.secondary_ip == null || var.secondary_network != null
      error_message = "VMs with a secondary_ip need secondary_network."
    }

    precondition {
      condition     = local.ubuntu_image_verified
      error_message = "${var.ubuntu_ova} does not match ubuntu_image_sha256 (or is a URL, which cannot be verified)."
    }
  }
}
