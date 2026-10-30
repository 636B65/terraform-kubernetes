# ---------------------------------------------------------------------------
# Common variables (identical for proxmox, vcenter, esxi and workstation)
# ---------------------------------------------------------------------------

variable "vms" {
  description = "VMs to create. Key = VM name/hostname. role is the Kubernetes role (control_plane or worker) used in the Ansible inventory. cpu, memory_mb and disk_gb can be set per VM, otherwise the defaults below are used."
  type = map(object({
    ip        = string
    role      = optional(string, "worker")
    cpu       = optional(number)
    memory_mb = optional(number)
    disk_gb   = optional(number)
  }))
  default = {
    "kube-cp01" = { ip = "192.168.1.101", role = "control_plane" }
    "kube-cp02" = { ip = "192.168.1.102", role = "control_plane" }
    "kube-cp03" = { ip = "192.168.1.103", role = "control_plane" }
    "kube-wl01" = { ip = "192.168.1.111", role = "worker" }
    "kube-wl02" = { ip = "192.168.1.112", role = "worker" }
    "kube-wl03" = { ip = "192.168.1.113", role = "worker" }
  }

  validation {
    condition     = alltrue([for vm in values(var.vms) : can(cidrhost("${vm.ip}/32", 0))])
    error_message = "Every VM must have a valid IPv4 address in the ip field (without /prefix)."
  }

  validation {
    condition     = alltrue([for vm in values(var.vms) : contains(["control_plane", "worker"], vm.role)])
    error_message = "role must be control_plane or worker."
  }
}

variable "ip_prefix_length" {
  description = "Netmask prefix length, e.g. 24 for 255.255.255.0."
  type        = number
  default     = 24
}

variable "gateway" {
  description = "Default gateway for the VMs."
  type        = string
}

variable "dns_servers" {
  description = "DNS servers."
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "dns_domain" {
  description = "DNS domain/search domain (optional)."
  type        = string
  default     = ""
}

variable "vm_username" {
  description = "User created in every VM (gets sudo)."
  type        = string
  default     = "ubuntu"
}

variable "vm_password" {
  description = "Password for the user. Also used for SSH login."
  type        = string
  sensitive   = true
}

variable "ssh_public_keys" {
  description = "Public SSH keys added for the user (optional)."
  type        = list(string)
  default     = []
}

variable "cpu" {
  description = "Number of vCPUs per VM (default)."
  type        = number
  default     = 2
}

variable "memory_mb" {
  description = "Memory per VM in MB (default)."
  type        = number
  default     = 4096
}

variable "disk_gb" {
  description = "Disk size per VM in GB (default). Must be at least the size of the Ubuntu image disk (about 10 GB). ansible-role-kubernetes recommends 60 GB for Longhorn."
  type        = number
  default     = 60
}

variable "timezone" {
  description = "Time zone in the VMs."
  type        = string
  default     = "Europe/Stockholm"
}

variable "extra_packages" {
  description = "Extra apt packages installed on first boot. open-iscsi and nfs-common are required by Longhorn in ansible-role-kubernetes."
  type        = list(string)
  default     = ["open-iscsi", "nfs-common"]
}

# ---------------------------------------------------------------------------
# Ansible (ansible-role-kubernetes)
# ---------------------------------------------------------------------------

variable "run_ansible" {
  description = "Run ansible-role-kubernetes against the VMs after they are created. Requires ansible-playbook and git on the machine running Terraform (Linux, macOS or WSL). The inventory is generated either way."
  type        = bool
  default     = false
}

variable "ansible_ssh_private_key_file" {
  description = "Private key Ansible uses for SSH (its public key must be in ssh_public_keys). null = use vm_password, which requires sshpass."
  type        = string
  default     = null
}

variable "ansible_role_source" {
  description = "Git URL of ansible-role-kubernetes."
  type        = string
  default     = "https://github.com/636B65/ansible-role-kubernetes.git"
}

variable "ansible_role_version" {
  description = "Tag, branch or commit of ansible-role-kubernetes to use."
  type        = string
  default     = "v2.0.0"
}

variable "kubernetes_api_vip" {
  description = "Free IP address for the Kubernetes API virtual IP (Keepalived). Must be in the VM network and not used by any VM. Required when run_ansible = true."
  type        = string
  default     = null

  validation {
    condition     = var.kubernetes_api_vip == null || can(cidrhost("${coalesce(var.kubernetes_api_vip, "0.0.0.0")}/32", 0))
    error_message = "kubernetes_api_vip must be a valid IPv4 address."
  }
}

variable "kubernetes_keepalived_auth_pass" {
  description = "Keepalived password, at most 8 characters. Required when run_ansible = true."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.kubernetes_keepalived_auth_pass == null || length(coalesce(var.kubernetes_keepalived_auth_pass, "x")) <= 8
    error_message = "kubernetes_keepalived_auth_pass must be at most 8 characters."
  }
}

variable "ansible_extra_vars" {
  description = "Extra variables for ansible-role-kubernetes, written to the inventory (e.g. { kubernetes_observability_enabled = true })."
  type        = any
  default     = {}
}

variable "ansible_playbook_args" {
  description = "Extra arguments for ansible-playbook, e.g. [\"--tags\", \"bootstrap\"]."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Proxmox
# ---------------------------------------------------------------------------

variable "proxmox_endpoint" {
  description = "Proxmox API URL, e.g. https://pve.lab.local:8006/"
  type        = string
}

variable "proxmox_api_token" {
  description = "API token in the format 'user@realm!tokenid=uuid'. Leave null to use username/password."
  type        = string
  default     = null
  sensitive   = true
}

variable "proxmox_username" {
  description = "Proxmox user (if no API token is used), e.g. root@pam."
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Password for proxmox_username (if no API token is used)."
  type        = string
  default     = null
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Allow self-signed certificates."
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH user on the Proxmox node (for uploading snippets)."
  type        = string
  default     = "root"
}

variable "proxmox_ssh_password" {
  description = "SSH password on the Proxmox node. Used when proxmox_ssh_agent = false."
  type        = string
  default     = null
  sensitive   = true
}

variable "proxmox_ssh_agent" {
  description = "Use the local ssh-agent for SSH to the node instead of a password."
  type        = bool
  default     = false
}

variable "proxmox_node" {
  description = "Proxmox node where the VMs are created."
  type        = string
  default     = "pve"
}

variable "vm_datastore" {
  description = "Datastore for VM disks."
  type        = string
  default     = "local-lvm"
}

variable "image_datastore" {
  description = "File-based datastore with content type 'ISO image' that the Ubuntu image is downloaded to."
  type        = string
  default     = "local"
}

variable "snippets_datastore" {
  description = "Datastore with the 'Snippets' content type enabled (for cloud-init user-data)."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Linux bridge the VMs are attached to."
  type        = string
  default     = "vmbr0"
}

variable "vlan_id" {
  description = "VLAN tag (null = none)."
  type        = number
  default     = null
}

variable "vm_id_start" {
  description = "First VM ID. The VMs get consecutive IDs starting here."
  type        = number
  default     = 9101
}

variable "cpu_type" {
  description = "CPU type, e.g. host or x86-64-v2-AES."
  type        = string
  default     = "host"
}

variable "ubuntu_image_url" {
  description = "URL of the Ubuntu 26.04 cloud image."
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
}

variable "start_on_boot" {
  description = "Start the VMs automatically when the node boots."
  type        = bool
  default     = true
}
