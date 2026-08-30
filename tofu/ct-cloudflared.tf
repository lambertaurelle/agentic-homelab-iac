# ==============================================================================
# Cloudflared Active-Active High Availability Tunnel Connectors
# CT 510: Primary Connector on Cluster Lead (Node: proxmox)
# CT 511: Secondary Connector on Compute Node (Node: tuxmox)
# ==============================================================================

# ------------------------------------------------------------------------------
# Primary Connector: CT 510 (Node: proxmox)
# ------------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "cloudflared_primary" {
  node_name = var.utility_node_name
  vm_id     = var.cloudflared_primary_ct_id

  description = "Managed by OpenTofu | Cloudflare Tunnel HA Connector (Primary)"
  tags        = var.cloudflared_primary_tags

  # Unprivileged container for lightweight and secure Cloudflare Tunnel connector
  unprivileged  = var.cloudflared_primary_unprivileged
  started       = true
  start_on_boot = true

  startup {
    order    = 2
    up_delay = 5
  }

  cpu {
    architecture = "amd64"
    cores        = var.cloudflared_primary_cores
  }

  memory {
    dedicated = var.cloudflared_primary_memory
    swap      = var.cloudflared_primary_swap
  }

  disk {
    datastore_id = var.cloudflared_primary_disk_storage
    size         = var.cloudflared_primary_disk_size
  }

  operating_system {
    template_file_id = var.cloudflared_primary_template_file_id
    type             = "debian"
  }

  initialization {
    hostname = var.cloudflared_primary_hostname

    ip_config {
      ipv4 {
        address = var.cloudflared_primary_ipv4_address
        gateway = var.cloudflared_primary_ipv4_gateway
      }
    }

    user_account {
      keys = var.cloudflared_primary_ssh_public_keys
    }
  }

  network_interface {
    name        = "eth0"
    bridge      = var.cloudflared_primary_network_bridge
    mac_address = var.cloudflared_primary_mac_address
    vlan_id     = var.cloudflared_primary_vlan_id
  }

  lifecycle {
    ignore_changes = [
      mount_point,
      device_passthrough,
      features,
      initialization,
      tags,
    ]
  }
}

# ------------------------------------------------------------------------------
# Secondary Connector: CT 511 (Node: tuxmox)
# ------------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "cloudflared_secondary" {
  node_name = var.compute_node_name
  vm_id     = var.cloudflared_secondary_ct_id

  description = "Managed by OpenTofu | Cloudflare Tunnel HA Connector (Secondary)"
  tags        = var.cloudflared_secondary_tags

  # Unprivileged container for lightweight and secure Cloudflare Tunnel connector
  unprivileged  = var.cloudflared_secondary_unprivileged
  started       = true
  start_on_boot = true

  startup {
    order    = 2
    up_delay = 5
  }

  cpu {
    architecture = "amd64"
    cores        = var.cloudflared_secondary_cores
  }

  memory {
    dedicated = var.cloudflared_secondary_memory
    swap      = var.cloudflared_secondary_swap
  }

  disk {
    datastore_id = var.cloudflared_secondary_disk_storage
    size         = var.cloudflared_secondary_disk_size
  }

  operating_system {
    template_file_id = var.cloudflared_secondary_template_file_id
    type             = "debian"
  }

  initialization {
    hostname = var.cloudflared_secondary_hostname

    ip_config {
      ipv4 {
        address = var.cloudflared_secondary_ipv4_address
        gateway = var.cloudflared_secondary_ipv4_gateway
      }
    }

    user_account {
      keys = var.cloudflared_secondary_ssh_public_keys
    }
  }

  network_interface {
    name        = "eth0"
    bridge      = var.cloudflared_secondary_network_bridge
    mac_address = var.cloudflared_secondary_mac_address
    vlan_id     = var.cloudflared_secondary_vlan_id
  }

  lifecycle {
    ignore_changes = [
      mount_point,
      device_passthrough,
      features,
      initialization,
      tags,
    ]
  }
}
