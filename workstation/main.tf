locals {
  # Packages cloud-init installs on this platform in addition to extra_packages.
  platform_packages = []

  # The home directory starts with "/" on Linux but with a drive letter on Windows.
  is_windows = coalesce(var.host_os, startswith(pathexpand("~"), "/") ? "linux" : "windows") == "windows"

  ws_dir = "C:/Program Files (x86)/VMware/VMware Workstation"

  vmrun        = coalesce(var.vmrun_path, local.is_windows ? "${local.ws_dir}/vmrun.exe" : "/usr/bin/vmrun")
  vdiskmanager = coalesce(var.vdiskmanager_path, local.is_windows ? "${local.ws_dir}/vmware-vdiskmanager.exe" : "/usr/bin/vmware-vdiskmanager")
  ovftool      = coalesce(var.ovftool_path, local.is_windows ? "${local.ws_dir}/OVFTool/ovftool.exe" : "/usr/bin/ovftool")

  script = (local.is_windows
    ? ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${abspath(path.module)}/scripts/vm.ps1"]
    : ["bash", "${abspath(path.module)}/scripts/vm.sh"]
  )
}

# Creates the template from the OVA once, when ubuntu_ova is set and the
# template does not exist yet. It is never powered on, and destroy keeps it.
resource "terraform_data" "template" {
  count = var.ubuntu_ova == null ? 0 : 1

  triggers_replace = {
    template = var.template_vmx
    ova      = var.ubuntu_ova
    network  = var.template_network
  }

  provisioner "local-exec" {
    interpreter = local.script
    command     = "template"

    environment = {
      OVFTOOL          = local.ovftool
      OVA              = var.ubuntu_ova
      TEMPLATE_VMX     = var.template_vmx
      TEMPLATE_NETWORK = var.template_network
      VM_VMX           = var.template_vmx
      VMRUN            = local.vmrun
    }
  }

  lifecycle {
    precondition {
      condition     = var.ubuntu_image_sha256 == null || filesha256(var.ubuntu_ova) == lower(coalesce(var.ubuntu_image_sha256, "x"))
      error_message = "${var.ubuntu_ova} does not match ubuntu_image_sha256."
    }
  }
}

resource "terraform_data" "vm" {
  for_each = local.vms

  depends_on = [terraform_data.template]

  # Changed values replace the VM (destroy + create).
  triggers_replace = {
    template  = var.template_vmx
    cpu       = each.value.cpu
    memory_mb = each.value.memory_mb
    disk_gb   = each.value.disk_gb
    # The second NIC's vnet counts only for VMs that have one, so the value
    # of single-NIC VMs stays the same.
    metadata = sha256(join("", [
      module.cloud_init.meta_data[each.key],
      each.value.macs == null ? "" : coalesce(var.secondary_vnet, "-"),
    ]))
    userdata = sha256(module.cloud_init.user_data[each.key])
  }

  # What destroy needs (provisioners with when = destroy may only read self).
  input = {
    name   = each.key
    vmx    = "${var.vm_directory}/${each.key}/${each.key}.vmx"
    vmrun  = local.vmrun
    script = local.script
  }

  provisioner "local-exec" {
    interpreter = local.script
    command     = "create"

    environment = {
      VMRUN        = local.vmrun
      VDISKMANAGER = local.vdiskmanager
      TEMPLATE_VMX = var.template_vmx
      VM_NAME      = each.key
      VM_VMX       = self.input.vmx
      CPU          = each.value.cpu
      MEMORY_MB    = each.value.memory_mb
      DISK_GB      = each.value.disk_gb
      METADATA_B64 = base64encode(module.cloud_init.meta_data[each.key])
      USERDATA_B64 = base64encode(module.cloud_init.user_data[each.key])
      START_MODE   = var.start_gui ? "gui" : "nogui"
      # Fixed MACs and the second NIC's vnet; empty = single NIC as cloned.
      MAC1           = each.value.macs == null ? "" : each.value.macs[0]
      MAC2           = each.value.macs == null ? "" : each.value.macs[1]
      SECONDARY_VNET = each.value.macs == null ? "" : coalesce(var.secondary_vnet, "-")
    }
  }

  lifecycle {
    precondition {
      condition     = each.value.secondary_ip == null || var.secondary_vnet != null
      error_message = "VMs with a secondary_ip need secondary_vnet."
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = self.input.script
    command     = "destroy"

    environment = {
      VMRUN  = self.input.vmrun
      VM_VMX = self.input.vmx
    }
  }
}
