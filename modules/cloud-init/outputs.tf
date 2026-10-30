output "user_data" {
  description = "cloud-config per VM (contains the password)."
  value       = local.user_data
  sensitive   = true
}

output "meta_data" {
  description = "meta-data per VM including network (for the VMware guestinfo datasource)."
  value       = local.meta_data
}

output "network_config" {
  description = "netplan v2 network configuration per VM."
  value       = local.network_config
}
