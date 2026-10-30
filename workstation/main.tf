locals {
  # The home directory starts with "/" on Linux but with a drive letter on Windows.
  is_windows = coalesce(var.host_os, startswith(pathexpand("~"), "/") ? "linux" : "windows") == "windows"

  ws_dir = "C:/Program Files (x86)/VMware/VMware Workstation"

  vmrun        = coalesce(var.vmrun_path, local.is_windows ? "${local.ws_dir}/vmrun.exe" : "/usr/bin/vmrun")
  vdiskmanager = coalesce(var.vdiskmanager_path, local.is_windows ? "${local.ws_dir}/vmware-vdiskmanager.exe" : "/usr/bin/vmware-vdiskmanager")

  script = (local.is_windows
    ? ["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "${abspath(path.module)}/scripts/vm.ps1"]
    : ["bash", "${abspath(path.module)}/scripts/vm.sh"]
  )
}

resource "terraform_data" "vm" {
  for_each = local.vms

  # Changed values replace the VM (destroy + create).
  triggers_replace = {
    template  = var.template_vmx
    cpu       = each.value.cpu
    memory_mb = each.value.memory_mb
    disk_gb   = each.value.disk_gb
    metadata  = sha256(module.cloud_init.meta_data[each.key])
    userdata  = sha256(module.cloud_init.user_data[each.key])
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
