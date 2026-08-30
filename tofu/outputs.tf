# ==============================================================================
# OpenTofu Core Infrastructure Outputs
# ==============================================================================

output "primary_node_name" {
  description = "Primary Proxmox VE hypervisor node name"
  value       = var.primary_node_name
}

output "adguard_primary_container_id" {
  description = "The CTID of the AdGuard Primary container"
  value       = proxmox_virtual_environment_container.adguard_primary.vm_id
}

output "adguard_primary_node" {
  description = "Proxmox node running AdGuard Primary"
  value       = proxmox_virtual_environment_container.adguard_primary.node_name
}

output "adguard_primary_ip_addresses" {
  description = "Assigned IP address of the AdGuard Primary container"
  value       = proxmox_virtual_environment_container.adguard_primary.initialization[0].ip_config[0].ipv4[0].address
}

output "cloudflared_primary_container_id" {
  description = "The CTID of the Cloudflared Primary container"
  value       = proxmox_virtual_environment_container.cloudflared_primary.vm_id
}

output "cloudflared_primary_node" {
  description = "Proxmox node running Cloudflared Primary"
  value       = proxmox_virtual_environment_container.cloudflared_primary.node_name
}

output "monitoring_container_id" {
  description = "The CTID of the Monitoring (Uptime Kuma) container"
  value       = proxmox_virtual_environment_container.monitoring.vm_id
}

output "monitoring_node" {
  description = "Proxmox node running Monitoring"
  value       = proxmox_virtual_environment_container.monitoring.node_name
}

output "monitoring_ip_addresses" {
  description = "Assigned IP address of the Monitoring container"
  value       = proxmox_virtual_environment_container.monitoring.initialization[0].ip_config[0].ipv4[0].address
}
