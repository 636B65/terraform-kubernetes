variable "vms" {
  description = "VM name => { ip, role, ansible_host } where role is control_plane or worker. When ansible_host is set, Ansible connects to it and ip becomes kubernetes_node_ip."
  type = map(object({
    ip           = string
    role         = string
    ansible_host = optional(string)
  }))
}

variable "output_dir" {
  description = "Directory for the generated inventory, requirements file and installed roles."
  type        = string
}

variable "run" {
  description = "Run the ansible-role-kubernetes playbook after the VMs are created."
  type        = bool
}

variable "username" {
  type = string
}

variable "password" {
  description = "Used for SSH (requires sshpass) when no private key file is given."
  type        = string
  sensitive   = true
}

variable "ssh_private_key_file" {
  type = string
}

variable "role_source" {
  type = string
}

variable "role_version" {
  type = string
}

variable "api_vip" {
  type = string
}

variable "api_vip_prefix" {
  type = number
}

variable "keepalived_auth_pass" {
  type      = string
  sensitive = true
}

variable "extra_vars" {
  type = any
}

variable "playbook_args" {
  type = list(string)
}

variable "offline" {
  description = "Install with kubernetes_offline_mode from the bundle in offline_bundle."
  type        = bool
}

variable "offline_bundle" {
  description = "Path of the offline bundle archive on the machine running Terraform."
  type        = string
}

variable "stage_bundle" {
  description = "Stage an offline bundle on the cluster and fetch it to offline_bundle."
  type        = bool
}

variable "remove_nodes" {
  description = "Nodes to drain and remove from the cluster with the role's remove_node tasks."
  type        = list(string)
  default     = []
}

variable "upgrade" {
  description = "Run the role's rolling upgrade when the role version or extra variables change."
  type        = bool
  default     = false
}

variable "etcd_backup_dir" {
  description = "Local directory for fetched etcd backups, used in the etcd_backup_command output. null = .ansible/etcd-backups."
  type        = string
  default     = null
}
