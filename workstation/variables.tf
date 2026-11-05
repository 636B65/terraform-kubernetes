# Generated from shared/variables.common.tf.tmpl by scripts/sync-common.sh; edit that file instead.

# ---------------------------------------------------------------------------
# Common variables (identical for proxmox, vcenter, esxi and workstation)
# ---------------------------------------------------------------------------

variable "vms" {
  description = "VMs to create. Key = VM name, hostname and Kubernetes node name. role is the Kubernetes role (control_plane or worker) used in the Ansible inventory. ansible_host optionally sets the address Ansible connects to (e.g. a DNS name); ip is then passed as kubernetes_node_ip. ipv6 adds a static IPv6 address to the primary NIC. secondary_ip adds a second NIC on secondary_network with that IPv4 address. cpu, memory_mb and disk_gb can be set per VM, otherwise the defaults below are used."
  type = map(object({
    ip           = string
    role         = optional(string, "worker")
    ansible_host = optional(string)
    ipv6         = optional(string)
    secondary_ip = optional(string)
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
    condition     = alltrue([for vm in values(var.vms) : vm.ipv6 == null || can(cidrhost("${coalesce(vm.ipv6, "::")}/128", 0))])
    error_message = "ipv6 must be an IPv6 address without /prefix."
  }

  validation {
    condition     = alltrue([for vm in values(var.vms) : vm.secondary_ip == null || can(cidrhost("${coalesce(vm.secondary_ip, "0.0.0.0")}/32", 0))])
    error_message = "secondary_ip must be an IPv4 address without /prefix."
  }

  validation {
    condition     = length(distinct(compact([for vm in values(var.vms) : vm.secondary_ip]))) == length(compact([for vm in values(var.vms) : vm.secondary_ip]))
    error_message = "Every secondary_ip must be unique."
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

variable "ipv6_prefix_length" {
  description = "IPv6 prefix length for the per-VM ipv6 addresses."
  type        = number
  default     = 64
}

variable "ipv6_gateway" {
  description = "IPv6 default gateway, or null for no IPv6 default route."
  type        = string
  default     = null
}

variable "secondary_prefix_length" {
  description = "Prefix length of the second NIC's network (per-VM secondary_ip). The second NIC gets no default route."
  type        = number
  default     = 24
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
  default     = "v3.2.0"
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

variable "velero" {
  description = "Velero backups of the cluster (and, with volume_backups, the volume data) to S3-compatible storage, installed by ansible-role-kubernetes. Off unless enabled = true; then bucket, access_key and secret_key are required, and s3_url for anything but AWS S3."
  type = object({
    enabled                  = optional(bool, false)
    bucket                   = optional(string, "")
    s3_url                   = optional(string, "")
    region                   = optional(string, "minio")
    access_key               = optional(string, "")
    secret_key               = optional(string, "")
    insecure_skip_tls_verify = optional(bool, false)
    volume_backups           = optional(bool, true)
    schedule                 = optional(string, "0 3 * * *")
    ttl                      = optional(string, "720h")
  })
  default   = {}
  sensitive = true
  nullable  = false

  validation {
    condition     = !var.velero.enabled || (var.velero.bucket != "" && var.velero.access_key != "" && var.velero.secret_key != "")
    error_message = "velero.bucket, velero.access_key and velero.secret_key are required when velero.enabled = true."
  }
}

variable "ansible_playbook_args" {
  description = "Extra arguments for ansible-playbook, e.g. [\"--tags\", \"bootstrap\"]."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Offline / air-gapped deployment
# ---------------------------------------------------------------------------

variable "offline" {
  description = "The VMs have no internet access. cloud-init skips package installs and disables the Ubuntu archive sources (unless apt_mirror is set), and ansible-role-kubernetes installs from offline_bundle with kubernetes_offline_mode."
  type        = bool
  default     = false
}

variable "apt_mirror" {
  description = "Internal Ubuntu archive mirror, e.g. http://mirror.lab.local/ubuntu. null = default sources (none when offline = true)."
  type        = string
  default     = null
}

variable "apt_security_mirror" {
  description = "Internal Ubuntu security mirror. null = apt_mirror."
  type        = string
  default     = null
}

variable "ntp_servers" {
  description = "NTP servers for the VMs, e.g. internal ones on an offline network. Empty = image default."
  type        = list(string)
  default     = []
}

variable "offline_bundle" {
  description = "Path of the offline bundle archive (a .tar of /opt/kubernetes-offline) on the machine running Terraform: written by stage_offline_bundle, read by offline = true."
  type        = string
  default     = null
}

variable "stage_offline_bundle" {
  description = "After installing the (online) cluster, stage an offline bundle with ansible-role-kubernetes (--tags offline_stage) and fetch it from the first controller to offline_bundle. Requires run_ansible = true."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Cluster operations (need run_ansible = true)
# ---------------------------------------------------------------------------

variable "remove_nodes" {
  description = "VMs to drain and remove from the Kubernetes cluster with the role's remove_node tasks. The VMs keep running: remove them from vms in a later apply. Add a VM to vms to join a new node."
  type        = list(string)
  default     = []
}

variable "kubernetes_upgrade" {
  description = "Run the role's rolling upgrade (one node at a time) whenever ansible_role_version or ansible_extra_vars change, e.g. after raising the role version or setting kubernetes_version."
  type        = bool
  default     = false
}

variable "etcd_backup_dir" {
  description = "Local directory that the etcd_backup_command output fetches the newest etcd backups into. null = .ansible/etcd-backups."
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# VMware Workstation
# ---------------------------------------------------------------------------

variable "template_vmx" {
  description = "Path to the .vmx of the Ubuntu 26.04 template (imported from the cloud image OVA, see README). The template must NEVER have been powered on."
  type        = string
}

variable "vm_directory" {
  description = "Directory where the VMs are created (one subdirectory per VM)."
  type        = string
}

variable "vmrun_path" {
  description = "Path to vmrun. null = default path for the OS."
  type        = string
  default     = null
}

variable "vdiskmanager_path" {
  description = "Path to vmware-vdiskmanager. null = default path for the OS."
  type        = string
  default     = null
}

variable "host_os" {
  description = "Host OS: 'windows' or 'linux'. null = auto-detect."
  type        = string
  default     = null

  validation {
    condition     = var.host_os == null || contains(["windows", "linux"], coalesce(var.host_os, "linux"))
    error_message = "host_os must be 'windows', 'linux' or null."
  }
}

variable "secondary_vnet" {
  description = "Virtual network (e.g. vmnet2) for the second NIC of VMs with a secondary_ip. Create it in the Virtual Network Editor."
  type        = string
  default     = null
}

variable "start_gui" {
  description = "Start the VMs with the Workstation GUI (true) or headless (false)."
  type        = bool
  default     = false
}
