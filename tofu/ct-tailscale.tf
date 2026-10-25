# ==============================================================================
# Tailscale Subnet Router & SSH Bastion LXC Container (CT 520) (Opt-in)
# Target Node: Utility Node (Node: node-1)
# Features: Unprivileged LXC, /dev/net/tun Passthrough, Subnet Router & SSH
# ==============================================================================

module "ct_tailscale" {
  count  = var.enable_tailscale ? 1 : 0
  source = "./modules/app-container"

  node_name   = var.utility_node_name
  vm_id       = var.tailscale_ct_id
  hostname    = var.tailscale_hostname
  description = "Managed by OpenTofu | Tailscale Subnet Router & SSH Bastion (${var.tailscale_hostname})"
  tags        = var.tailscale_tags

  unprivileged     = true
  nesting          = true
  started          = true
  start_on_boot    = true
  startup_order    = 2
  startup_up_delay = 5

  cores        = var.tailscale_cores
  memory       = var.tailscale_memory
  swap         = var.tailscale_swap
  disk_size    = var.tailscale_disk_size
  disk_storage = var.tailscale_disk_storage

  mac_address  = var.tailscale_mac_address
  ipv4_address = var.tailscale_ipv4_address
  ipv4_gateway = var.tailscale_ipv4_gateway

  # Note: /dev/net/tun device passthrough is applied idempotently via
  # scripts/install-tailscale.sh (Proxmox API restricts dev0 to root@pam)

  ssh_public_keys = length(var.tailscale_ssh_public_keys) > 0 ? var.tailscale_ssh_public_keys : (
    length(var.app_ssh_public_keys) > 0 ? var.app_ssh_public_keys : var.cloudflared_primary_ssh_public_keys
  )
}

moved {
  from = module.ct_tailscale
  to   = module.ct_tailscale[0]
}
