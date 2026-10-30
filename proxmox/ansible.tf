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
  playbook_args        = var.ansible_playbook_args

  depends_on = [proxmox_virtual_environment_vm.vm]
}
