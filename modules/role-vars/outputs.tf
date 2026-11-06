output "vars" {
  description = "Role variables for the inventory (sensitive: they can hold the Velero keys)."
  value       = local.vars
  sensitive   = true
}

output "bundle_vars" {
  description = "The variables that decide what goes into the offline bundle: the components that are enabled, pinned versions and extra images. No credentials."
  value = nonsensitive({
    for k, v in local.vars : k => v
    if can(regex("^kubernetes_((.+_)?(enabled|version)|offline_extra_images|registry_images)$", k)) && k != "kubernetes_offline_mode"
  })
}
