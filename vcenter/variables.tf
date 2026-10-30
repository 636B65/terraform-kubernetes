# ---------------------------------------------------------------------------
# Common variables (identical for proxmox, vcenter, esxi and workstation)
# ---------------------------------------------------------------------------

variable "vms" {
  description = "VMs to create. Key = VM name/hostname. cpu, memory_mb and disk_gb can be set per VM, otherwise the defaults below are used."
  type = map(object({
    ip        = string
    cpu       = optional(number)
    memory_mb = optional(number)
    disk_gb   = optional(number)
  }))
  default = {
    "ubuntu-01" = { ip = "192.168.1.101" }
    "ubuntu-02" = { ip = "192.168.1.102" }
    "ubuntu-03" = { ip = "192.168.1.103" }
    "ubuntu-04" = { ip = "192.168.1.104" }
    "ubuntu-05" = { ip = "192.168.1.105" }
    "ubuntu-06" = { ip = "192.168.1.106" }
  }

  validation {
    condition     = alltrue([for vm in values(var.vms) : can(cidrhost("${vm.ip}/32", 0))])
    error_message = "Every VM must have a valid IPv4 address in the ip field (without /prefix)."
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
  description = "Disk size per VM in GB (default). Must be at least the size of the Ubuntu image disk (about 10 GB)."
  type        = number
  default     = 40
}

variable "timezone" {
  description = "Time zone in the VMs."
  type        = string
  default     = "Europe/Stockholm"
}

variable "extra_packages" {
  description = "Extra apt packages installed on first boot."
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
