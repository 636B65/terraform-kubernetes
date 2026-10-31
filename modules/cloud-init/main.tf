# Generates cloud-init (user-data, meta-data, network-config) per VM.
# Shared by all platforms so that user, password, SSH and IP are
# configured identically regardless of hypervisor.

locals {
  network_config = {
    for name, ip in var.vms : name => {
      version = 2
      ethernets = {
        primary = {
          match     = { name = var.interface_match }
          dhcp4     = false
          dhcp6     = false
          addresses = ["${ip}/${var.ip_prefix_length}"]
          routes    = [{ to = "default", via = var.gateway }]
          nameservers = merge(
            { addresses = var.dns_servers },
            var.dns_domain == "" ? {} : { search = [var.dns_domain] },
          )
        }
      }
    }
  }

  user = merge(
    {
      name              = var.username
      gecos             = var.username
      groups            = ["adm", "sudo"]
      shell             = "/bin/bash"
      sudo              = "ALL=(ALL) NOPASSWD:ALL"
      lock_passwd       = false
      plain_text_passwd = var.password
    },
    length(var.ssh_public_keys) == 0 ? {} : { ssh_authorized_keys = var.ssh_public_keys },
  )

  user_data = {
    for name, ip in var.vms : name => join("\n", ["#cloud-config", yamlencode({
      hostname         = name
      fqdn             = var.dns_domain == "" ? name : "${name}.${var.dns_domain}"
      manage_etc_hosts = true
      timezone         = var.timezone

      # SSH: password login enabled, root disabled, service enabled.
      ssh_pwauth   = true
      disable_root = true
      users        = [local.user]
      chpasswd     = { expire = false }

      package_update = true
      packages       = distinct(concat(["openssh-server"], var.extra_packages))

      runcmd = [
        ["systemctl", "enable", "--now", "ssh"],
        ["sh", "-c", "systemctl enable --now qemu-guest-agent 2>/dev/null || true"],
      ]

      # On Proxmox the first boot can lose a race: cloud-init cannot rename the
      # interface because it is already up on a DHCP lease ("Error renaming ...
      # [busy]"), so the VM keeps a DHCP address and the static one only
      # applies after a reboot. Reboot once, after the packages are installed,
      # when the static address is missing. cloud-init runs power_state once
      # per instance, so this cannot loop.
      power_state = {
        mode      = "reboot"
        message   = "Rebooting to apply the static network configuration"
        timeout   = 30
        condition = "! ip -4 -o addr show | grep -q ' ${ip}/'"
      }
    })])
  }

  meta_data = {
    for name, ip in var.vms : name => yamlencode({
      instance-id    = name
      local-hostname = name
      network        = local.network_config[name]
    })
  }
}
