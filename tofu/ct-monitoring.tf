# ==============================================================================
# Monitoring (Uptime Kuma) LXC Container
# Target Node: Utility Node (Node: node-1)
# Features: Privileged LXC with Nesting for Docker + Docker Compose stack
# ==============================================================================

resource "proxmox_virtual_environment_container" "monitoring" {
  node_name = var.utility_node_name
  vm_id     = var.monitoring_ct_id

  description = "Managed by OpenTofu | Uptime Kuma Monitoring & Discord Alerting"
  tags        = var.monitoring_tags

  # Privileged mode ensures straightforward Docker nested container execution
  unprivileged  = var.monitoring_unprivileged
  started       = true
  start_on_boot = true

  startup {
    order    = 3
    up_delay = 10
  }

  cpu {
    architecture = "amd64"
    cores        = var.monitoring_cores
  }

  memory {
    dedicated = var.monitoring_memory
    swap      = var.monitoring_swap
  }

  disk {
    datastore_id = var.monitoring_disk_storage
    size         = var.monitoring_disk_size
  }

  operating_system {
    template_file_id = var.monitoring_template_file_id
    type             = "debian"
  }

  initialization {
    hostname = var.monitoring_hostname

    ip_config {
      ipv4 {
        address = var.monitoring_ipv4_address
        gateway = var.monitoring_ipv4_gateway
      }
    }

    user_account {
      keys = var.monitoring_ssh_public_keys
    }
  }

  network_interface {
    name        = "eth0"
    bridge      = var.monitoring_network_bridge
    mac_address = var.monitoring_mac_address
    vlan_id     = var.monitoring_vlan_id
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
