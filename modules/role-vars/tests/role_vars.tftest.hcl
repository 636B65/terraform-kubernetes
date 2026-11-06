# terraform test (in modules/role-vars): the defaults, Velero and the bundle
# variables.

run "defaults" {
  command = plan

  assert {
    condition     = output.bundle_vars == { kubernetes_argocd_enabled = true }
    error_message = "Argo CD is on by default and nothing else is set."
  }
}

run "extra_vars_override" {
  command = plan

  variables {
    extra_vars = {
      kubernetes_argocd_enabled  = false
      kubernetes_ingress_enabled = true
      kubernetes_version         = "1.36.5"
      kubernetes_api_vip         = "10.0.0.10"
    }
  }

  assert {
    condition = output.bundle_vars == {
      kubernetes_argocd_enabled  = false
      kubernetes_ingress_enabled = true
      kubernetes_version         = "1.36.5"
    }
    error_message = "extra_vars override the defaults, and only bundle-relevant variables are kept."
  }
}

run "velero_enabled_without_secrets_in_bundle_vars" {
  command = plan

  variables {
    velero = {
      enabled    = true
      bucket     = "backups"
      access_key = "velero"
      secret_key = "s3cret"
    }
  }

  assert {
    condition     = output.bundle_vars.kubernetes_velero_enabled == true && !contains(keys(output.bundle_vars), "kubernetes_velero_s3_secret_key")
    error_message = "The bundle needs Velero but not its keys."
  }

  assert {
    condition     = nonsensitive(output.vars.kubernetes_velero_s3_secret_key) == "s3cret"
    error_message = "The inventory variables carry the Velero keys."
  }
}
