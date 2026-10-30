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

output "ansible_inventory" {
  description = "Generated Ansible inventory for ansible-role-kubernetes."
  value       = module.ansible.inventory_file
}

output "ansible_command" {
  description = "Command to run ansible-role-kubernetes manually."
  value       = module.ansible.command
}
