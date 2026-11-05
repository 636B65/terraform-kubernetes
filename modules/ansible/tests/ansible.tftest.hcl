# terraform test (in modules/ansible): checks the generated inventory and the
# guards, with a mocked local provider (no files written, no Ansible run).

mock_provider "local" {}

variables {
  vms = {
    "kube-cp01" = { ip = "192.168.1.101", role = "control_plane" }
    "kube-wl01" = { ip = "192.168.1.111", role = "worker", ansible_host = "kube-wl01.mgmt.lab" }
  }
  output_dir           = "/tmp/terraform-test-ansible"
  run                  = false
  username             = "ubuntu"
  password             = "secret"
  ssh_private_key_file = null
  role_source          = "https://github.com/636B65/ansible-role-kubernetes.git"
  role_version         = "v3.2.0"
  api_vip              = "192.168.1.100"
  api_vip_prefix       = 24
  keepalived_auth_pass = "k8s-vip1"
  extra_vars           = {}
  playbook_args        = []
  offline              = false
  offline_bundle       = null
  stage_bundle         = false
}

run "inventory" {
  command = plan

  assert {
    condition     = yamldecode(local_sensitive_file.inventory.content).all.children.k8s_control_plane.hosts == { "kube-cp01" = { ansible_host = "192.168.1.101" } }
    error_message = "Control-plane group is wrong."
  }

  assert {
    condition     = yamldecode(local_sensitive_file.inventory.content).all.children.k8s_workers.hosts["kube-wl01"] == { ansible_host = "kube-wl01.mgmt.lab", kubernetes_node_ip = "192.168.1.111" }
    error_message = "ansible_host must override the connection address and ip become kubernetes_node_ip."
  }

  assert {
    condition     = yamldecode(local_sensitive_file.inventory.content).all.vars.ansible_password == "secret"
    error_message = "Without a key the password is used."
  }

  assert {
    condition     = yamldecode(local_sensitive_file.inventory.content).all.vars.kubernetes_api_vip == "192.168.1.100"
    error_message = "Role variables missing."
  }

  assert {
    condition     = !contains(keys(yamldecode(local_sensitive_file.inventory.content).all.vars), "kubernetes_offline_mode")
    error_message = "Online inventories do not set offline mode."
  }

  assert {
    condition     = local_sensitive_file.inventory.file_permission == "0600"
    error_message = "The inventory holds secrets and must be 0600."
  }

  assert {
    condition     = length(terraform_data.playbook) == 0 && output.kubeconfig == null
    error_message = "Nothing runs without run = true."
  }

  assert {
    condition     = yamldecode(local_file.requirements.content).roles[0].version == "v3.2.0"
    error_message = "Role version not pinned in requirements.yml."
  }
}

run "ssh_key_and_extra_vars" {
  command = plan

  variables {
    ssh_private_key_file = "/keys/id_ed25519"
    extra_vars           = { kubernetes_ingress_enabled = true }
  }

  assert {
    condition     = yamldecode(local_sensitive_file.inventory.content).all.vars.ansible_ssh_private_key_file == "/keys/id_ed25519" && !contains(keys(yamldecode(local_sensitive_file.inventory.content).all.vars), "ansible_password")
    error_message = "With a key, no password goes into the inventory."
  }

  assert {
    condition     = yamldecode(local_sensitive_file.inventory.content).all.vars.kubernetes_ingress_enabled == true
    error_message = "extra_vars must reach the inventory."
  }
}

run "velero_off_by_default" {
  command = plan

  assert {
    condition     = length([for k in keys(yamldecode(local_sensitive_file.inventory.content).all.vars) : k if startswith(k, "kubernetes_velero_")]) == 0
    error_message = "Velero is off unless enabled; the role defaults apply."
  }
}

run "velero_enabled" {
  command = plan

  variables {
    velero = {
      enabled                  = true
      bucket                   = "k8s-backups"
      s3_url                   = "https://minio.lab.local:9000"
      region                   = "minio"
      access_key               = "velero"
      secret_key               = "s3cret"
      insecure_skip_tls_verify = false
      volume_backups           = true
      schedule                 = "0 3 * * *"
      ttl                      = "720h"
    }
  }

  assert {
    condition = (
      yamldecode(local_sensitive_file.inventory.content).all.vars.kubernetes_velero_enabled == true
      && yamldecode(local_sensitive_file.inventory.content).all.vars.kubernetes_velero_bucket == "k8s-backups"
      && yamldecode(local_sensitive_file.inventory.content).all.vars.kubernetes_velero_s3_url == "https://minio.lab.local:9000"
      && yamldecode(local_sensitive_file.inventory.content).all.vars.kubernetes_velero_s3_secret_key == "s3cret"
    )
    error_message = "An enabled velero object must reach the role's kubernetes_velero_* variables."
  }
}

run "offline_install" {
  command = plan

  variables {
    run            = true
    offline        = true
    offline_bundle = "/kits/kubernetes-offline.tar"
  }

  assert {
    condition     = yamldecode(local_sensitive_file.inventory.content).all.vars.kubernetes_offline_mode == true
    error_message = "Offline mode missing."
  }

  assert {
    condition     = yamldecode(local_sensitive_file.inventory.content).all.vars.offline_bundle == "/kits/kubernetes-offline.tar"
    error_message = "Bundle path missing."
  }

  assert {
    condition     = length(terraform_data.playbook) == 1 && output.kubeconfig == "/tmp/terraform-test-ansible/kubeconfig"
    error_message = "The playbook runs and the kubeconfig is fetched."
  }
}

run "run_without_vip_fails" {
  command = plan

  variables {
    run     = true
    api_vip = null
  }

  expect_failures = [terraform_data.playbook]
}

run "offline_without_bundle_fails" {
  command = plan

  variables {
    run     = true
    offline = true
  }

  expect_failures = [terraform_data.playbook]
}

run "remove_unknown_node_fails" {
  command = plan

  variables {
    run          = true
    remove_nodes = ["kube-wl99"]
  }

  expect_failures = [terraform_data.remove_nodes]
}

run "remove_node" {
  command = plan

  variables {
    run          = true
    remove_nodes = ["kube-wl01"]
  }

  assert {
    condition     = length(terraform_data.remove_nodes) == 1
    error_message = "remove_nodes runs the removal."
  }
}

run "stage_while_offline_fails" {
  command = plan

  variables {
    run            = true
    offline        = true
    offline_bundle = "/kits/kubernetes-offline.tar"
    stage_bundle   = true
  }

  expect_failures = [terraform_data.stage_bundle]
}

run "upgrade" {
  command = plan

  variables {
    run     = true
    upgrade = true
  }

  assert {
    condition     = length(terraform_data.upgrade) == 1
    error_message = "upgrade = true adds the upgrade run."
  }
}

run "dry_run_fetches_no_kubeconfig" {
  command = plan

  variables {
    run           = true
    playbook_args = ["--check"]
  }

  assert {
    condition     = output.kubeconfig == null
    error_message = "A dry run has no kubeconfig."
  }
}
