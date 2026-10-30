variable "vms" {
  description = "VM name => IP address."
  type        = map(string)
}

variable "ip_prefix_length" {
  type = number
}

variable "gateway" {
  type = string
}

variable "dns_servers" {
  type = list(string)
}

variable "dns_domain" {
  type = string
}

variable "username" {
  type = string
}

variable "password" {
  type      = string
  sensitive = true
}

variable "ssh_public_keys" {
  type = list(string)
}

variable "timezone" {
  type = string
}

variable "extra_packages" {
  type = list(string)
}

variable "interface_match" {
  description = "Name pattern of the network interface that gets the static IP (netplan match.name)."
  type        = string
  default     = "en*"
}
