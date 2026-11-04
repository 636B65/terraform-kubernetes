output "inventory_file" {
  value = local_sensitive_file.inventory.filename
}

output "command" {
  description = "Command to run the playbook manually."
  value       = "cd ${local.out} && ansible-galaxy role install --force -r requirements.yml -p roles && ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventory.yml ${local.playbook}"
}

output "kubeconfig" {
  description = "Admin kubeconfig fetched from the first controller after the playbook ran, or null."
  value       = var.run && !local.dry_run ? local.kubeconfig : null
}

output "etcd_backup_command" {
  description = "Command that fetches the newest etcd backups from the controllers."
  value       = "cd ${local.out} && ANSIBLE_ROLES_PATH=roles ansible-playbook -i inventory.yml -e etcd_backup_dir='${var.etcd_backup_dir == null ? "${local.out}/etcd-backups" : abspath(pathexpand(var.etcd_backup_dir))}' ${local.playbooks["fetch-etcd-backup"]}"
}
