# ==============================================================================
# AdGuard Home Active-Active High Availability DNS & DHCP Nodes
# CT 501: Primary AdGuard Home on Cluster Lead (Node: node-1)
# CT 502: Secondary AdGuard Home on Compute Node (Node: node-2)
# ==============================================================================

# ------------------------------------------------------------------------------
# Primary AdGuard Home: CT 501 (Node: node-1)
# ------------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "adguard_primary" {
  node_name = var.utility_node_name
  vm_id     = var.adguard_primary_ct_id

  description = "Managed by OpenTofu | AdGuard Home DNS & DHCP (Primary)"
  tags        = var.adguard_primary_tags

  # Privileged mode for direct networking & systemd management
  unprivileged  = var.adguard_primary_unprivileged
  started       = true
  start_on_boot = true

  startup {
    order    = 1
    up_delay = 0
  }

  # Features (nesting) configured via pct set post-creation
  # features {
  #   nesting = true
  # }

  cpu {
    architecture = "amd64"
    cores        = var.adguard_primary_cores
  }

  memory {
    dedicated = var.adguard_primary_memory
    swap      = var.adguard_primary_swap
  }

  disk {
    datastore_id = var.adguard_primary_disk_storage
    size         = var.adguard_primary_disk_size
  }

  operating_system {
    template_file_id = var.adguard_primary_template_file_id
    type             = "debian"
  }

  initialization {
    hostname = var.adguard_primary_hostname

    ip_config {
      ipv4 {
        address = var.adguard_primary_ipv4_address
        gateway = var.adguard_primary_ipv4_gateway
      }
    }

    dns {
      servers = var.adguard_dns_servers
    }

    user_account {
      keys = var.adguard_primary_ssh_public_keys
    }
  }

  network_interface {
    name        = "eth0"
    bridge      = var.adguard_primary_network_bridge
    mac_address = var.adguard_primary_mac_address
    vlan_id     = var.adguard_primary_vlan_id
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
# Secondary AdGuard Home: CT 502 (Node: node-2)
# ------------------------------------------------------------------------------
resource "proxmox_virtual_environment_container" "adguard_secondary" {
  node_name = var.compute_node_name
  vm_id     = var.adguard_secondary_ct_id

  description = "Managed by OpenTofu | AdGuard Home DNS & DHCP (Secondary)"
  tags        = var.adguard_secondary_tags

  # Privileged mode for direct networking & systemd management
  unprivileged  = var.adguard_secondary_unprivileged
  started       = true
  start_on_boot = true

  startup {
    order    = 1
    up_delay = 0
  }

  # Features (nesting) configured via pct set post-creation
  # features {
  #   nesting = true
  # }

  cpu {
    architecture = "amd64"
    cores        = var.adguard_secondary_cores
  }

  memory {
    dedicated = var.adguard_secondary_memory
    swap      = var.adguard_secondary_swap
  }

  disk {
    datastore_id = var.adguard_secondary_disk_storage
    size         = var.adguard_secondary_disk_size
  }

  operating_system {
    template_file_id = var.adguard_secondary_template_file_id
    type             = "debian"
  }

  initialization {
    hostname = var.adguard_secondary_hostname

    ip_config {
      ipv4 {
        address = var.adguard_secondary_ipv4_address
        gateway = var.adguard_secondary_ipv4_gateway
      }
    }

    dns {
      servers = var.adguard_dns_servers
    }

    user_account {
      keys = var.adguard_secondary_ssh_public_keys
    }
  }

  network_interface {
    name        = "eth0"
    bridge      = var.adguard_secondary_network_bridge
    mac_address = var.adguard_secondary_mac_address
    vlan_id     = var.adguard_secondary_vlan_id
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
