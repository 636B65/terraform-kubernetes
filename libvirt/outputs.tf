output "vms" {
  description = "Created VMs."
  value = {
    for name, vm in local.vms : name => {
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

output "kubeconfig" {
  description = "Admin kubeconfig fetched after run_ansible: export KUBECONFIG=$(terraform output -raw kubeconfig)."
  value       = module.ansible.kubeconfig
}

output "etcd_backup_command" {
  description = "Command that fetches the newest etcd backups from the controllers."
  value       = module.ansible.etcd_backup_command
}
