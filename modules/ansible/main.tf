# Generates an Ansible inventory for ansible-role-kubernetes and optionally
# installs the role and runs the playbook against the new VMs.

locals {
  hosts_in = {
    for role in ["control_plane", "worker"] : role => {
      for name, vm in var.vms : name => (
        vm.ansible_host == null
        ? { ansible_host = vm.ip }
        : { ansible_host = vm.ansible_host, kubernetes_node_ip = vm.ip }
      ) if vm.role == role
    }
  }

  connection_vars = merge(
    {
      ansible_user            = var.username
      ansible_become          = true
      ansible_ssh_common_args = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    },
    var.ssh_private_key_file == null
    ? { ansible_password = var.password }
    : { ansible_ssh_private_key_file = pathexpand(var.ssh_private_key_file) },
  )

  # Unset (null) values are left out so the role defaults apply.
  role_vars = merge(
    { for k, v in {
      loginusername                   = var.username
      kubernetes_api_vip              = var.api_vip
      kubernetes_api_vip_prefix       = var.api_vip_prefix
      kubernetes_keepalived_auth_pass = var.keepalived_auth_pass
    } : k => v if v != null },
    var.extra_vars,
  )

  inventory = yamlencode({
    all = {
      vars = merge(local.connection_vars, local.role_vars)
      children = {
        k8s_control_plane = { hosts = local.hosts_in.control_plane }
        k8s_workers       = { hosts = local.hosts_in.worker }
      }
    }
  })

  requirements = yamlencode({
    roles = [{
      name    = "ansible-role-kubernetes"
      src     = var.role_source
      scm     = "git"
      version = var.role_version
    }]
  })

  playbook = abspath("${path.module}/../../ansible/site.yml")
  out      = abspath(var.output_dir)
}

resource "local_sensitive_file" "inventory" {
  filename        = "${local.out}/inventory.yml"
  content         = local.inventory
  file_permission = "0600"
}

resource "local_file" "requirements" {
  filename        = "${local.out}/requirements.yml"
  content         = local.requirements
  file_permission = "0644"
}

resource "terraform_data" "playbook" {
  count = var.run ? 1 : 0

  # Runs again when the inventory, role version or playbook changes.
  triggers_replace = [
    sha256(local.inventory),
    sha256(local.requirements),
    filesha256(local.playbook),
  ]

  provisioner "local-exec" {
    working_dir = local.out
    command     = <<-EOT
      set -e
      ansible-galaxy role install --force -r requirements.yml -p roles
      ansible-playbook -i inventory.yml ${join(" ", [for a in var.playbook_args : format("%q", a)])} '${local.playbook}'
    EOT

    environment = {
      ANSIBLE_ROLES_PATH        = "${local.out}/roles"
      ANSIBLE_HOST_KEY_CHECKING = "False"
      ANSIBLE_FORCE_COLOR       = "1"
    }
  }

  lifecycle {
    precondition {
      condition     = var.api_vip != null && var.keepalived_auth_pass != null
      error_message = "run_ansible = true requires kubernetes_api_vip and kubernetes_keepalived_auth_pass."
    }
  }

  depends_on = [local_sensitive_file.inventory, local_file.requirements]
}

check "api_vip" {
  assert {
    condition     = var.api_vip == null || !contains([for vm in values(var.vms) : vm.ip], coalesce(var.api_vip, "-"))
    error_message = "kubernetes_api_vip must be a free IP address, not the IP of a VM."
  }
}
