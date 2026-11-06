# The ansible-role-kubernetes variables these templates choose, in one place:
# the defaults that differ from the role's, the velero variable and
# ansible_extra_vars. Used for the inventory (modules/ansible) and for the
# offline bundle (scripts/prepare-offline.sh), so the bundle always contains
# what the cluster installs.

locals {
  # Defaults of these templates that differ from the role's.
  defaults = {
    kubernetes_argocd_enabled = true
  }

  # A for filter, not a conditional: that would turn the values into strings.
  velero = { for k, v in {
    kubernetes_velero_enabled                     = true
    kubernetes_velero_bucket                      = var.velero.bucket
    kubernetes_velero_s3_url                      = var.velero.s3_url
    kubernetes_velero_s3_region                   = var.velero.region
    kubernetes_velero_s3_access_key               = var.velero.access_key
    kubernetes_velero_s3_secret_key               = var.velero.secret_key
    kubernetes_velero_s3_insecure_skip_tls_verify = var.velero.insecure_skip_tls_verify
    kubernetes_velero_volume_backups              = var.velero.volume_backups
    kubernetes_velero_schedule                    = var.velero.schedule
    kubernetes_velero_ttl                         = var.velero.ttl
  } : k => v if var.velero.enabled }

  vars = merge(local.defaults, local.velero, var.extra_vars)
}
