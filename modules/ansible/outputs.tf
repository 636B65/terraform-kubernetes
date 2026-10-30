output "inventory_file" {
  value = local_sensitive_file.inventory.filename
}

output "command" {
  description = "Command to run the playbook manually."
  value       = "cd ${local.out} && ansible-galaxy role install --force -r requirements.yml -p roles && ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventory.yml ${local.playbook}"
}
