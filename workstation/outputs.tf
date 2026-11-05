output "vms" {
  description = "Created VMs."
  value = {
    for name, vm in local.vms : name => {
      vmx       = terraform_data.vm[name].output.vmx
      ip        = vm.ip
      cpu       = vm.cpu
      memory_mb = vm.memory_mb
      disk_gb   = vm.disk_gb
      ssh       = "ssh ${var.vm_username}@${vm.ip}"
    }
  }
}
