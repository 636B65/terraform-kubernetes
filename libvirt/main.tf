locals {
  # Either a libvirt network or a host bridge; the unused one stays null.
  interface_source = {
    network = var.network_bridge == null ? { network = var.network_name } : null
    bridge  = var.network_bridge == null ? null : { bridge = var.network_bridge }
  }
}

# The Ubuntu 26.04 cloud image, downloaded once into the pool. Every VM disk
# is a copy-on-write overlay on top of it.
resource "libvirt_volume" "ubuntu" {
  name = "ubuntu-26.04-server-cloudimg-amd64.qcow2"
  pool = var.storage_pool

  target = {
    format = { type = "qcow2" }
  }

  create = {
    content = { url = var.ubuntu_image_url }
  }
}

resource "libvirt_volume" "disk" {
  for_each = local.vms

  name     = "${each.key}.qcow2"
  pool     = var.storage_pool
  capacity = each.value.disk_gb * 1024 * 1024 * 1024

  target = {
    format = { type = "qcow2" }
  }

  backing_store = {
    path   = libvirt_volume.ubuntu.path
    format = { type = "qcow2" }
  }
}

# cloud-init NoCloud ISO (user, password, SSH, static IP) per VM.
resource "libvirt_cloudinit_disk" "init" {
  for_each = local.vms

  name      = "${each.key}-cloudinit"
  user_data = module.cloud_init.user_data[each.key]
  meta_data = yamlencode({
    instance-id    = each.key
    local-hostname = each.key
  })
  network_config = yamlencode(module.cloud_init.network_config[each.key])
}

resource "libvirt_volume" "cloudinit" {
  for_each = local.vms

  name = "${each.key}-cloudinit.iso"
  pool = var.storage_pool

  create = {
    content = { url = libvirt_cloudinit_disk.init[each.key].path }
  }
}

resource "libvirt_domain" "vm" {
  for_each = local.vms

  name        = each.key
  type        = "kvm"
  description = "Ubuntu 26.04 - managed by Terraform"

  vcpu        = each.value.cpu
  memory      = each.value.memory_mb
  memory_unit = "MiB"

  autostart = var.autostart
  running   = true

  cpu = {
    mode = var.cpu_mode
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  devices = {
    disks = [
      {
        source = {
          volume = {
            pool   = libvirt_volume.disk[each.key].pool
            volume = libvirt_volume.disk[each.key].name
          }
        }
        target = { bus = "virtio", dev = "vda" }
        driver = { type = "qcow2", discard = "unmap" }
      },
      {
        device = "cdrom"
        source = {
          volume = {
            pool   = libvirt_volume.cloudinit[each.key].pool
            volume = libvirt_volume.cloudinit[each.key].name
          }
        }
        target = { bus = "sata", dev = "sda" }
      },
    ]

    interfaces = [
      {
        model  = { type = "virtio" }
        source = local.interface_source
      },
    ]

    graphics = [
      {
        vnc = {
          auto_port = true
          listen    = "127.0.0.1"
        }
      },
    ]
  }
}
