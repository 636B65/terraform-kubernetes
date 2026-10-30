terraform {
  required_version = ">= 1.5.0"

  required_providers {
    esxi = {
      source  = "josenk/esxi"
      version = "~> 1.10"
    }
  }
}

# Requires VMware OVF Tool (ovftool) in PATH on the machine running
# Terraform, and SSH enabled on the ESXi host.
provider "esxi" {
  esxi_hostname = var.esxi_hostname
  esxi_hostport = var.esxi_ssh_port
  esxi_hostssl  = var.esxi_https_port
  esxi_username = var.esxi_username
  esxi_password = var.esxi_password
}
