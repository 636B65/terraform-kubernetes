variable "vms" {
  description = "VM name => { ip, role } where role is control_plane or worker."
  type = map(object({
    ip   = string
    role = string
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
