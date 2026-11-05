output "vms" {
  description = "Created VMs."
  value = {
    for name, vm in local.vms : name => {
      vm_id     = proxmox_virtual_environment_vm.vm[name].vm_id
      ip        = vm.ip
      cpu       = vm.cpu
      memory_mb = vm.memory_mb
      disk_gb   = vm.disk_gb
      ssh       = "ssh ${var.vm_username}@${vm.ip}"
    }
  }
}
