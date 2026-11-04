# Generates cloud-init (user-data, meta-data, network-config) per VM.
# Shared by all platforms so that user, password, SSH and IP are
# configured identically regardless of hypervisor.

locals {
  network_config = {
    for name, vm in var.vms : name => {
      version = 2
      ethernets = merge(
        {
          primary = {
            # One NIC: match it by name. Two NICs: match each by its MAC.
            match = {
              for k, v in {
                name       = vm.macs == null ? var.interface_match : null
                macaddress = vm.macs == null ? null : vm.macs[0]
              } : k => v if v != null
            }
            dhcp4 = false
            dhcp6 = false
            addresses = concat(
              ["${vm.ip}/${var.ip_prefix_length}"],
              vm.ipv6 == null ? [] : ["${vm.ipv6}/${var.ipv6_prefix_length}"],
            )
            routes = concat(
              [{ to = "default", via = var.gateway }],
              vm.ipv6 == null || var.ipv6_gateway == null ? [] : [{ to = "::/0", via = var.ipv6_gateway }],
            )
            nameservers = merge(
              { addresses = var.dns_servers },
              var.dns_domain == "" ? {} : { search = [var.dns_domain] },
            )
          }
        },
        # Through JSON, so both branches have the same type.
        jsondecode(vm.macs == null ? "{}" : jsonencode({
          secondary = {
            match     = { macaddress = vm.macs[1] }
            dhcp4     = false
            dhcp6     = false
            addresses = ["${vm.secondary_ip}/${var.secondary_prefix_length}"]
          }
        })),
      )
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

  # Offline without a mirror: no package installs (ansible-role-kubernetes
  # installs what it needs from its offline bundle) and the Ubuntu archive
  # sources are disabled, so apt-get update only uses reachable sources.
  no_apt = var.offline && var.apt_mirror == null

  # Optional top-level cloud-config sections, rendered separately and joined
  # with the rest (their keys do not overlap).
  optional_sections = join("", [
    local.no_apt ? "" : yamlencode({
      package_update = true
      packages       = distinct(concat(["openssh-server"], var.extra_packages))
    }),
    var.apt_mirror == null ? "" : yamlencode({
      apt = {
        primary  = [{ arches = ["default"], uri = var.apt_mirror }]
        security = [{ arches = ["default"], uri = coalesce(var.apt_security_mirror, var.apt_mirror) }]
      }
    }),
    length(var.ntp_servers) == 0 ? "" : yamlencode({
      ntp = { enabled = true, servers = var.ntp_servers }
    }),
  ])

  disable_sources = local.no_apt ? [
    ["sh", "-c", "for f in /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list; do if [ -s \"$f\" ]; then mv \"$f\" \"$f.disabled\"; fi; done"],
  ] : []

  user_data = {
    for name, vm in var.vms : name => join("\n", ["#cloud-config", local.optional_sections, yamlencode({
      hostname         = name
      fqdn             = var.dns_domain == "" ? name : "${name}.${var.dns_domain}"
      manage_etc_hosts = true
      timezone         = var.timezone

      # SSH: password login enabled, root disabled, service enabled.
      ssh_pwauth   = true
      disable_root = true
      users        = [local.user]
      chpasswd     = { expire = false }

      runcmd = concat(local.disable_sources, [
        ["systemctl", "enable", "--now", "ssh"],
        ["sh", "-c", "systemctl enable --now qemu-guest-agent 2>/dev/null || true"],
      ])

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
        condition = "! ip -4 -o addr show | grep -q ' ${vm.ip}/'"
      }
    })])
  }

  meta_data = {
    for name, vm in var.vms : name => yamlencode({
      instance-id    = name
      local-hostname = name
      network        = local.network_config[name]
    })
  }
}
