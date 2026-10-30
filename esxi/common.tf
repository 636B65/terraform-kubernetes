locals {
  vms = {
    for name, vm in var.vms : name => {
      ip           = vm.ip
      role         = vm.role
      ansible_host = vm.ansible_host
      cpu          = coalesce(vm.cpu, var.cpu)
      memory_mb    = coalesce(vm.memory_mb, var.memory_mb)
      disk_gb      = coalesce(vm.disk_gb, var.disk_gb)
    }
  }
}

module "cloud_init" {
  source = "../modules/cloud-init"

  vms              = { for name, vm in local.vms : name => vm.ip }
  ip_prefix_length = var.ip_prefix_length
  gateway          = var.gateway
  dns_servers      = var.dns_servers
  dns_domain       = var.dns_domain
  username         = var.vm_username
  password         = var.vm_password
  ssh_public_keys  = var.ssh_public_keys
  timezone         = var.timezone
  extra_packages   = var.extra_packages
}
