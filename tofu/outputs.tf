
output "cloudflared_primary_container_id" {
  description = "The CTID of the Cloudflared Primary container"
  value       = proxmox_virtual_environment_container.cloudflared_primary.vm_id
}

output "cloudflared_primary_node" {
  description = "Proxmox node running Cloudflared Primary"
  value       = proxmox_virtual_environment_container.cloudflared_primary.node_name
}

output "cloudflared_primary_ip_addresses" {
  description = "Assigned IP addresses of the Cloudflared Primary container"
  value       = proxmox_virtual_environment_container.cloudflared_primary.initialization[0].ip_config[0].ipv4[0].address
}

output "cloudflared_secondary_container_id" {
  description = "The CTID of the Cloudflared Secondary container"
  value       = proxmox_virtual_environment_container.cloudflared_secondary.vm_id
}

output "cloudflared_secondary_node" {
  description = "Proxmox node running Cloudflared Secondary"
  value       = proxmox_virtual_environment_container.cloudflared_secondary.node_name
}

output "cloudflared_secondary_ip_addresses" {
  description = "Assigned IP addresses of the Cloudflared Secondary container"
  value       = proxmox_virtual_environment_container.cloudflared_secondary.initialization[0].ip_config[0].ipv4[0].address
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
  description = "Assigned IP addresses of the AdGuard Primary container"
  value       = proxmox_virtual_environment_container.adguard_primary.initialization[0].ip_config[0].ipv4[0].address
}

output "adguard_secondary_container_id" {
  description = "The CTID of the AdGuard Secondary container"
  value       = proxmox_virtual_environment_container.adguard_secondary.vm_id
}

output "adguard_secondary_node" {
  description = "Proxmox node running AdGuard Secondary"
  value       = proxmox_virtual_environment_container.adguard_secondary.node_name
}

output "adguard_secondary_ip_addresses" {
  description = "Assigned IP addresses of the AdGuard Secondary container"
  value       = proxmox_virtual_environment_container.adguard_secondary.initialization[0].ip_config[0].ipv4[0].address
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
  description = "Assigned IP addresses of the Monitoring container"
  value       = proxmox_virtual_environment_container.monitoring.initialization[0].ip_config[0].ipv4[0].address
}

output "app_node_name" {
  description = "Default Proxmox node for declarative production workload containers"
  value       = var.app_node_name
}
