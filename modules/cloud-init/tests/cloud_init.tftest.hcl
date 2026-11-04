# terraform test (in modules/cloud-init): checks the rendered cloud-init.

variables {
  vms = {
    "kube-cp01" = { ip = "192.168.1.101" }
    "kube-cp02" = {
      ip           = "192.168.1.102"
      ipv6         = "2001:db8::102"
      secondary_ip = "10.10.0.102"
      macs         = ["00:50:56:00:00:01", "00:50:56:00:00:02"]
    }
  }
  ip_prefix_length = 24
  gateway          = "192.168.1.1"
  dns_servers      = ["192.168.1.1"]
  dns_domain       = "lab.local"
  username         = "ubuntu"
  password         = "secret"
  ssh_public_keys  = ["ssh-ed25519 AAAA test"]
  timezone         = "Europe/Stockholm"
  extra_packages   = ["open-iscsi"]
}

run "single_nic_online" {
  command = plan

  assert {
    condition     = output.network_config["kube-cp01"].ethernets.primary.match == { name = "en*" }
    error_message = "A single NIC is matched by name."
  }

  assert {
    condition     = output.network_config["kube-cp01"].ethernets.primary.addresses == ["192.168.1.101/24"]
    error_message = "Wrong primary address."
  }

  assert {
    condition     = !contains(keys(output.network_config["kube-cp01"].ethernets), "secondary")
    error_message = "A VM without secondary_ip must not get a second NIC."
  }

  assert {
    condition     = yamldecode(output.user_data["kube-cp01"]).packages == ["openssh-server", "open-iscsi"]
    error_message = "Online VMs install openssh-server and the extra packages."
  }

  assert {
    condition     = yamldecode(output.user_data["kube-cp01"]).ssh_pwauth && yamldecode(output.user_data["kube-cp01"]).users[0].ssh_authorized_keys == ["ssh-ed25519 AAAA test"]
    error_message = "SSH password login and the public keys must be set."
  }

  assert {
    condition     = startswith(output.user_data["kube-cp01"], "#cloud-config\n")
    error_message = "user-data must start with #cloud-config."
  }

  assert {
    condition     = yamldecode(output.meta_data["kube-cp01"])["local-hostname"] == "kube-cp01"
    error_message = "meta-data must set the hostname."
  }
}

run "second_nic_and_ipv6" {
  command = plan

  variables {
    ipv6_gateway = "2001:db8::1"
  }

  assert {
    condition     = output.network_config["kube-cp02"].ethernets.primary.match == { macaddress = "00:50:56:00:00:01" }
    error_message = "With two NICs the primary is matched by MAC."
  }

  assert {
    condition     = output.network_config["kube-cp02"].ethernets.secondary.match == { macaddress = "00:50:56:00:00:02" }
    error_message = "The second NIC is matched by its MAC."
  }

  assert {
    condition     = output.network_config["kube-cp02"].ethernets.secondary.addresses == ["10.10.0.102/24"]
    error_message = "Wrong secondary address."
  }

  assert {
    condition     = !contains(keys(output.network_config["kube-cp02"].ethernets.secondary), "routes")
    error_message = "The second NIC must not get a default route."
  }

  assert {
    condition     = output.network_config["kube-cp02"].ethernets.primary.addresses == ["192.168.1.102/24", "2001:db8::102/64"]
    error_message = "The IPv6 address belongs on the primary NIC."
  }

  assert {
    condition     = contains(output.network_config["kube-cp02"].ethernets.primary.routes, { to = "::/0", via = "2001:db8::1" })
    error_message = "IPv6 default route missing."
  }

  assert {
    condition     = length(output.network_config["kube-cp01"].ethernets.primary.routes) == 1
    error_message = "A VM without ipv6 gets no IPv6 route."
  }
}

run "offline" {
  command = plan

  variables {
    offline     = true
    ntp_servers = ["10.0.0.5"]
  }

  assert {
    condition     = !contains(keys(yamldecode(output.user_data["kube-cp01"])), "packages") && !contains(keys(yamldecode(output.user_data["kube-cp01"])), "package_update")
    error_message = "Offline VMs without a mirror install no packages."
  }

  assert {
    condition     = strcontains(yamldecode(output.user_data["kube-cp01"]).runcmd[0][2], "ubuntu.sources")
    error_message = "Offline VMs disable the Ubuntu archive sources first."
  }

  assert {
    condition     = yamldecode(output.user_data["kube-cp01"]).ntp == { enabled = true, servers = ["10.0.0.5"] }
    error_message = "NTP servers missing."
  }
}

run "offline_with_mirror" {
  command = plan

  variables {
    offline    = true
    apt_mirror = "http://mirror.lab.local/ubuntu"
  }

  assert {
    condition     = yamldecode(output.user_data["kube-cp01"]).apt.primary[0].uri == "http://mirror.lab.local/ubuntu" && yamldecode(output.user_data["kube-cp01"]).apt.security[0].uri == "http://mirror.lab.local/ubuntu"
    error_message = "The mirror must be used for the archive and security sources."
  }

  assert {
    condition     = contains(yamldecode(output.user_data["kube-cp01"]).packages, "open-iscsi")
    error_message = "With a mirror, packages are installed even offline."
  }

  assert {
    condition     = yamldecode(output.user_data["kube-cp01"]).runcmd[0] == ["systemctl", "enable", "--now", "ssh"]
    error_message = "With a mirror, the sources are not disabled."
  }
}
