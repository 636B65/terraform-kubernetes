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
      kubernetes_offline_mode         = var.offline ? true : null
      offline_bundle                  = var.offline && var.offline_bundle != null ? abspath(pathexpand(var.offline_bundle)) : null
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

  playbooks = {
    for name in ["site", "fetch-offline-bundle", "fetch-kubeconfig", "remove-node", "upgrade", "fetch-etcd-backup"] :
    name => abspath("${path.module}/../../ansible/${name}.yml")
  }
  playbook       = local.playbooks["site"]
  fetch_playbook = local.playbooks["fetch-offline-bundle"]
  out            = abspath(var.output_dir)
  kubeconfig     = "${local.out}/kubeconfig"
  playbook_args  = join(" ", [for a in var.playbook_args : format("%q", a)])

  # Dry runs install no cluster, so there is no kubeconfig to fetch.
  dry_run = length(setintersection(var.playbook_args, ["--check", "-C", "--syntax-check", "--list-hosts", "--list-tasks", "--list-tags"])) > 0

  ansible_env = {
    ANSIBLE_ROLES_PATH        = "${local.out}/roles"
    ANSIBLE_HOST_KEY_CHECKING = "False"
    ANSIBLE_FORCE_COLOR       = "1"
  }
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
      ansible-playbook -i inventory.yml ${local.playbook_args} '${local.playbook}'
      %{if !local.dry_run~}
      ansible-playbook -i inventory.yml -e kubeconfig='${local.kubeconfig}' '${local.playbooks["fetch-kubeconfig"]}'
      %{endif~}
    EOT

    environment = local.ansible_env
  }

  lifecycle {
    precondition {
      condition     = var.api_vip != null && var.keepalived_auth_pass != null
      error_message = "run_ansible = true requires kubernetes_api_vip and kubernetes_keepalived_auth_pass."
    }

    precondition {
      condition     = !var.offline || var.offline_bundle != null
      error_message = "offline = true with run_ansible = true requires offline_bundle (the staged bundle archive)."
    }
  }

  depends_on = [local_sensitive_file.inventory, local_file.requirements]
}

# Drains and removes nodes from the cluster (the VMs stay until they are
# removed from vms). Runs again when the list changes.
resource "terraform_data" "remove_nodes" {
  count = length(var.remove_nodes) > 0 ? 1 : 0

  triggers_replace = [sort(var.remove_nodes)]

  provisioner "local-exec" {
    working_dir = local.out
    command     = "ansible-playbook -i inventory.yml -e ${format("%q", jsonencode({ kubernetes_remove_nodes = var.remove_nodes }))} '${local.playbooks["remove-node"]}'"
    environment = local.ansible_env
  }

  lifecycle {
    precondition {
      condition     = var.run
      error_message = "remove_nodes requires run_ansible = true."
    }

    precondition {
      condition     = length(setsubtract(var.remove_nodes, keys(var.vms))) == 0
      error_message = "Every name in remove_nodes must be a VM in vms. Remove a node from the cluster first, and from vms in a later apply."
    }
  }

  depends_on = [terraform_data.playbook]
}

# Rolling upgrade to the Kubernetes version pinned by the role (or set in
# ansible_extra_vars). Runs when upgrades are enabled and the role version or
# the extra variables change.
resource "terraform_data" "upgrade" {
  count = var.upgrade ? 1 : 0

  triggers_replace = [
    sha256(local.requirements),
    sha256(jsonencode(var.extra_vars)),
  ]

  provisioner "local-exec" {
    working_dir = local.out
    command     = "ansible-playbook -i inventory.yml '${local.playbooks["upgrade"]}'"
    environment = local.ansible_env
  }

  lifecycle {
    precondition {
      condition     = var.run
      error_message = "kubernetes_upgrade requires run_ansible = true."
    }
  }

  depends_on = [terraform_data.playbook]
}

# Stages an offline bundle on the (online) cluster and fetches it from the
# first controller to offline_bundle, for an offline install elsewhere.
resource "terraform_data" "stage_bundle" {
  count = var.stage_bundle ? 1 : 0

  triggers_replace = [
    sha256(local.inventory),
    sha256(local.requirements),
    var.offline_bundle,
  ]

  provisioner "local-exec" {
    working_dir = local.out
    command     = <<-EOT
      set -e
      ansible-playbook -i inventory.yml --tags offline_stage '${local.playbook}'
      ansible-playbook -i inventory.yml -e offline_bundle='${abspath(pathexpand(coalesce(var.offline_bundle, "-")))}' '${local.fetch_playbook}'
    EOT

    environment = local.ansible_env
  }

  lifecycle {
    precondition {
      condition     = var.run && !var.offline && var.offline_bundle != null
      error_message = "stage_offline_bundle = true requires run_ansible = true, offline = false and offline_bundle (where to save the bundle)."
    }
  }

  depends_on = [terraform_data.playbook]
}

check "api_vip" {
  assert {
    condition     = var.api_vip == null || !contains([for vm in values(var.vms) : vm.ip], coalesce(var.api_vip, "-"))
    error_message = "kubernetes_api_vip must be a free IP address, not the IP of a VM."
  }
}
