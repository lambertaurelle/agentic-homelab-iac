# ==============================================================================
# Declarative Application LXC Container Module
# Supports Dynamic Node Placement (Compute Node: node-2 vs Utility Node: node-1)
# Features: Unprivileged LXC (UID shifted), Nesting for Docker, Dual-Tier SSH
# ==============================================================================

resource "proxmox_virtual_environment_container" "app" {
  node_name = var.node_name
  vm_id     = var.vm_id

  description = var.description
  tags        = var.tags

  unprivileged  = var.unprivileged
  started       = var.started
  start_on_boot = var.start_on_boot

  startup {
    order    = var.startup_order
    up_delay = var.startup_up_delay
  }

  features {
    nesting = var.nesting
  }

  cpu {
    architecture = "amd64"
    cores        = var.cores
  }

  memory {
    dedicated = var.memory
    swap      = var.swap
  }

  disk {
    datastore_id = var.disk_storage
    size         = var.disk_size
  }

  operating_system {
    template_file_id = var.template_file_id
    type             = var.os_type
  }

  initialization {
    hostname = var.hostname

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.ipv4_gateway
      }
    }

    dynamic "dns" {
      for_each = var.dns_servers != null ? [1] : []
      content {
        servers = var.dns_servers
      }
    }

    user_account {
      keys = var.ssh_public_keys
    }
  }

  network_interface {
    name        = "eth0"
    bridge      = var.network_bridge
    mac_address = var.mac_address
    vlan_id     = var.vlan_id
  }

  dynamic "mount_point" {
    for_each = var.mount_points
    content {
      volume    = mount_point.value.volume
      path      = mount_point.value.path
      read_only = mount_point.value.read_only
    }
  }

  dynamic "device_passthrough" {
    for_each = var.device_passthroughs
    content {
      path = device_passthrough.value.path
    }
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
