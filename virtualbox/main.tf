locals {
  # The home directory starts with "/" on Linux and macOS but with a drive
  # letter on Windows.
  is_windows = coalesce(var.host_os, startswith(pathexpand("~"), "/") ? "unix" : "windows") == "windows"

  vboxmanage = coalesce(var.vboxmanage_path, local.is_windows ? "C:/Program Files/Oracle/VirtualBox/VBoxManage.exe" : "VBoxManage")

  script = (local.is_windows
    ? ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${abspath(path.module)}/scripts/vm.ps1"]
    : ["bash", "${abspath(path.module)}/scripts/vm.sh"]
  )

  work_dir = abspath(var.vm_directory)

  # A URL is downloaded once; a local path is used as is.
  ova = (can(regex("^https?://", var.ubuntu_ova))
    ? "${local.work_dir}/ubuntu-26.04-server-cloudimg-amd64.ova"
    : abspath(var.ubuntu_ova)
  )
}

# Downloads the OVA once, before the VMs are imported in parallel.
resource "terraform_data" "image" {
  triggers_replace = [var.ubuntu_ova]

  provisioner "local-exec" {
    interpreter = local.script
    command     = "image"

    environment = {
      OVA_SOURCE    = var.ubuntu_ova
      OVA           = local.ova
      OVA_SHA256    = var.ubuntu_image_sha256 == null ? "" : var.ubuntu_image_sha256
      VERIFY_SHA256 = var.verify_ubuntu_image ? "1" : "0"
    }
  }
}

resource "terraform_data" "vm" {
  for_each = local.vms

  # Changed values replace the VM (destroy + create).
  triggers_replace = {
    ova          = var.ubuntu_ova
    cpu          = each.value.cpu
    memory_mb    = each.value.memory_mb
    disk_gb      = each.value.disk_gb
    network_type = var.network_type
    network_name = var.network_name
    userdata     = sha256(module.cloud_init.user_data[each.key])
    # The second NIC's network counts only for VMs that have one, so the
    # value of single-NIC VMs stays the same.
    network = sha256(join("", [
      yamlencode(module.cloud_init.network_config[each.key]),
      each.value.macs == null ? "" : "${var.secondary_network_type}/${coalesce(var.secondary_network_name, "-")}",
    ]))
  }

  # What destroy needs (provisioners with when = destroy may only read self).
  input = {
    name       = each.key
    vboxmanage = local.vboxmanage
    work_dir   = local.work_dir
    script     = local.script
  }

  provisioner "local-exec" {
    interpreter = local.script
    command     = "create"

    environment = {
      VBOXMANAGE   = local.vboxmanage
      OVA          = local.ova
      VM_NAME      = each.key
      WORK_DIR     = local.work_dir
      CPU          = each.value.cpu
      MEMORY_MB    = each.value.memory_mb
      DISK_GB      = each.value.disk_gb
      NETWORK_TYPE = var.network_type
      NETWORK_NAME = var.network_name
      # VirtualBox takes MACs without separators; empty = no fixed MAC.
      MAC1                   = each.value.macs == null ? "" : upper(replace(each.value.macs[0], ":", ""))
      MAC2                   = each.value.macs == null ? "" : upper(replace(each.value.macs[1], ":", ""))
      SECONDARY_NETWORK_TYPE = each.value.macs == null ? "" : var.secondary_network_type
      SECONDARY_NETWORK_NAME = each.value.macs == null ? "" : coalesce(var.secondary_network_name, "-")
      USERDATA_B64           = base64encode(module.cloud_init.user_data[each.key])
      METADATA_B64           = base64encode(yamlencode({ instance-id = each.key, local-hostname = each.key }))
      NETWORK_CONFIG_B64     = base64encode(yamlencode(module.cloud_init.network_config[each.key]))
      START_TYPE             = var.start_gui ? "gui" : "headless"
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = self.input.script
    command     = "destroy"

    environment = {
      VBOXMANAGE = self.input.vboxmanage
      VM_NAME    = self.input.name
      WORK_DIR   = self.input.work_dir
    }
  }

  lifecycle {
    precondition {
      condition     = each.value.secondary_ip == null || var.secondary_network_name != null
      error_message = "VMs with a secondary_ip need secondary_network_name (and secondary_network_type)."
    }
  }

  depends_on = [terraform_data.image]
}
