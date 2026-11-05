# Generated from shared/ansible.tf.tmpl by scripts/sync-common.sh; edit that file instead.

# Generates .ansible/inventory.yml for ansible-role-kubernetes and, when
# run_ansible = true, runs the role once the VMs exist.
module "ansible" {
  source = "../modules/ansible"

  vms                  = { for name, vm in local.vms : name => { ip = vm.ip, role = vm.role, ansible_host = vm.ansible_host } }
  output_dir           = "${path.module}/.ansible"
  run                  = var.run_ansible
  username             = var.vm_username
  password             = var.vm_password
  ssh_private_key_file = var.ansible_ssh_private_key_file
  role_source          = var.ansible_role_source
  role_version         = var.ansible_role_version
  api_vip              = var.kubernetes_api_vip
  api_vip_prefix       = var.ip_prefix_length
  keepalived_auth_pass = var.kubernetes_keepalived_auth_pass
  extra_vars           = var.ansible_extra_vars
  velero               = var.velero
  playbook_args        = var.ansible_playbook_args
  offline              = var.offline
  offline_bundle       = var.offline_bundle
  stage_bundle         = var.stage_offline_bundle
  remove_nodes         = var.remove_nodes
  upgrade              = var.kubernetes_upgrade
  etcd_backup_dir      = var.etcd_backup_dir

  depends_on = [esxi_guest.vm]
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
