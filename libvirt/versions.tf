terraform {
  required_version = ">= 1.5.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.9.9"
    }
  }
}

# qemu:///system on the local host, or e.g. qemu+ssh://user@kvm01/system for
# a remote host.
provider "libvirt" {
  uri = var.libvirt_uri
}
