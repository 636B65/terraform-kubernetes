resource "esxi_guest" "vm" {
  for_each = local.vms

  guest_name = each.key
  disk_store = var.datastore
  notes      = "Ubuntu 26.04 - managed by Terraform"

  ovf_source = var.ubuntu_ova

  numvcpus       = each.value.cpu
  memsize        = each.value.memory_mb
  boot_disk_size = each.value.disk_gb
  boot_disk_type = "thin"
  power          = "on"

  network_interfaces {
    virtual_network = var.network
    nic_type        = "vmxnet3"
  }

  # cloud-init (VMware datasource) reads IP, user, password and SSH from here.
  guestinfo = {
    "metadata"          = base64encode(module.cloud_init.meta_data[each.key])
    "metadata.encoding" = "base64"
    "userdata"          = base64encode(module.cloud_init.user_data[each.key])
    "userdata.encoding" = "base64"
  }

  guest_startup_timeout  = 180
  guest_shutdown_timeout = 30
}
