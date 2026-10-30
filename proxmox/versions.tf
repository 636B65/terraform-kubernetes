terraform {
  required_version = ">= 1.5.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.86"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  username  = var.proxmox_api_token == null ? var.proxmox_username : null
  password  = var.proxmox_api_token == null ? var.proxmox_password : null
  insecure  = var.proxmox_insecure

  # SSH to the node is required to upload cloud-init snippets.
  ssh {
    agent    = var.proxmox_ssh_agent
    username = var.proxmox_ssh_username
    password = var.proxmox_ssh_agent ? null : var.proxmox_ssh_password
  }
}
