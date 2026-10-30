# ---------------------------------------------------------------------------
# Common variables (identical for proxmox, vcenter, esxi and workstation)
# ---------------------------------------------------------------------------

variable "vms" {
  description = "VMs to create. Key = VM name, hostname and Kubernetes node name. role is the Kubernetes role (control_plane or worker) used in the Ansible inventory. ansible_host optionally sets the address Ansible connects to (e.g. a DNS name); ip is then passed as kubernetes_node_ip. cpu, memory_mb and disk_gb can be set per VM, otherwise the defaults below are used."
  type = map(object({
    ip           = string
    role         = optional(string, "worker")
    ansible_host = optional(string)
    cpu          = optional(number)
    memory_mb    = optional(number)
    disk_gb      = optional(number)
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
    condition     = alltrue([for name in keys(var.vms) : can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", name))])
    error_message = "VM names are used as hostnames and Kubernetes node names: lowercase letters, digits and hyphens, starting and ending with a letter or digit."
  }

  validation {
    condition     = length(distinct([for vm in values(var.vms) : vm.ip])) == length(var.vms)
    error_message = "Every VM must have a unique IP address."
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
  description = "Tag, branch or commit of ansible-role-kubernetes to use. Kept up to date by the track-ansible-role workflow."
  type        = string
  default     = "v3.0.0"
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
# vCenter
# ---------------------------------------------------------------------------

variable "vsphere_server" {
  description = "vCenter server (FQDN or IP)."
  type        = string
}

variable "vsphere_user" {
  description = "vCenter user, e.g. administrator@vsphere.local."
  type        = string
}

variable "vsphere_password" {
  description = "Password for the vCenter user."
  type        = string
  sensitive   = true
}

variable "vsphere_insecure" {
  description = "Allow self-signed certificates."
  type        = bool
  default     = true
}

variable "datacenter" {
  description = "vCenter datacenter."
  type        = string
}

variable "cluster" {
  description = "Cluster the VMs run in."
  type        = string
}

variable "datastore" {
  description = "Datastore for the VMs."
  type        = string
}

variable "network" {
  description = "Port group/network, e.g. 'VM Network'."
  type        = string
  default     = "VM Network"
}

variable "vm_folder" {
  description = "VM folder in vCenter (relative to the datacenter). Empty string = root folder."
  type        = string
  default     = ""
}

variable "template_name" {
  description = "Name of the Ubuntu 26.04 template (imported from the cloud image OVA, see README)."
  type        = string
  default     = "ubuntu-2604-template"
}
