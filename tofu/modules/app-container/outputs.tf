# ==============================================================================
# Declarative Application LXC Container Module - Outputs
# ==============================================================================

output "container_id" {
  description = "The CTID of the application container"
  value       = proxmox_virtual_environment_container.app.vm_id
}

output "node" {
  description = "Proxmox hypervisor node running the application container"
  value       = proxmox_virtual_environment_container.app.node_name
}

output "hostname" {
  description = "Hostname configured on the container"
  value       = proxmox_virtual_environment_container.app.initialization[0].hostname
}

output "ip_addresses" {
  description = "Assigned IP configuration of the container"
  value       = proxmox_virtual_environment_container.app.initialization[0].ip_config[0].ipv4[0].address
}

output "mac_address" {
  description = "Network interface MAC address"
  value       = proxmox_virtual_environment_container.app.network_interface[0].mac_address
}

output "unprivileged" {
  description = "Whether the container runs in unprivileged LXC isolation mode"
  value       = proxmox_virtual_environment_container.app.unprivileged
}

output "tags" {
  description = "Tags associated with the container"
  value       = proxmox_virtual_environment_container.app.tags
}
