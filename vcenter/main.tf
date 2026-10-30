data "vsphere_datacenter" "dc" {
  name = var.datacenter
}

data "vsphere_compute_cluster" "cluster" {
  name          = var.cluster
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "ds" {
  name          = var.datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "net" {
  name          = var.network
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "template" {
  name          = var.template_name
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_virtual_machine" "vm" {
  for_each = local.vms

  name             = each.key
  folder           = var.vm_folder == "" ? null : var.vm_folder
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id
  datastore_id     = data.vsphere_datastore.ds.id
  annotation       = "Ubuntu 26.04 - managed by Terraform"

  num_cpus = each.value.cpu
  memory   = each.value.memory_mb
  guest_id = data.vsphere_virtual_machine.template.guest_id
  firmware = data.vsphere_virtual_machine.template.firmware

  scsi_type = data.vsphere_virtual_machine.template.scsi_type

  network_interface {
    network_id   = data.vsphere_network.net.id
    adapter_type = data.vsphere_virtual_machine.template.network_interface_types[0]
  }

  disk {
    label            = "disk0"
    size             = max(each.value.disk_gb, data.vsphere_virtual_machine.template.disks[0].size)
    thin_provisioned = data.vsphere_virtual_machine.template.disks[0].thin_provisioned
  }

  # The Ubuntu OVA has a CD-ROM drive; keep it as a client device.
  cdrom {
    client_device = true
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.template.id
  }

  # cloud-init (VMware datasource) reads IP, user, password and SSH from here.
  extra_config = {
    "guestinfo.metadata"          = base64encode(module.cloud_init.meta_data[each.key])
    "guestinfo.metadata.encoding" = "base64"
    "guestinfo.userdata"          = base64encode(module.cloud_init.user_data[each.key])
    "guestinfo.userdata.encoding" = "base64"
  }

  wait_for_guest_net_timeout = 10
}
