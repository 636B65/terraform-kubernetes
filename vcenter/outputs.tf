output "vms" {
  description = "Created VMs."
  value = {
    for name, vm in local.vms : name => {
      ip        = vm.ip
      cpu       = vm.cpu
      memory_mb = vm.memory_mb
      disk_gb   = vm.disk_gb
      moid      = vsphere_virtual_machine.vm[name].moid
      ssh       = "ssh ${var.vm_username}@${vm.ip}"
    }
  }
}
