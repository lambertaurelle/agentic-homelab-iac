# ==============================================================================
# Offsite Cloud Backup LXC Container (Ephemeral Worker)
# Target Node: Utility Node (Node: node-1)
# Features: Streaming differential backups to cloud storage via Restic + Rclone
# ==============================================================================

resource "proxmox_virtual_environment_container" "offsite_backup" {
  node_name = var.utility_node_name
  vm_id     = var.offsite_backup_ct_id

  description = "Managed by OpenTofu | Differential Offsite Cloud Backup Worker"
  tags        = var.offsite_backup_tags

  # Privileged mode ensures transparent read-only access to host/NFS volume bind mounts
  unprivileged  = var.offsite_backup_unprivileged
  started       = var.offsite_backup_started
  start_on_boot = var.offsite_backup_start_on_boot

  startup {
    order    = 4
    up_delay = 10
  }

  cpu {
    architecture = "amd64"
    cores        = var.offsite_backup_cores
  }

  memory {
    dedicated = var.offsite_backup_memory
    swap      = var.offsite_backup_swap
  }

  disk {
    datastore_id = var.offsite_backup_disk_storage
    size         = var.offsite_backup_disk_size
  }

  operating_system {
    template_file_id = var.offsite_backup_template_file_id
    type             = "debian"
  }

  initialization {
    hostname = var.offsite_backup_hostname

    ip_config {
      ipv4 {
        address = var.offsite_backup_ipv4_address
        gateway = var.offsite_backup_ipv4_gateway
      }
    }

    user_account {
      keys = var.offsite_backup_ssh_public_keys
    }
  }

  network_interface {
    name        = "eth0"
    bridge      = var.offsite_backup_network_bridge
    mac_address = var.offsite_backup_mac_address
    vlan_id     = var.offsite_backup_vlan_id
  }

  # Mount points are applied via pct set post-creation on node-1 due to Proxmox API token permission constraints (bind mount points restricted to root@pam)
  # dynamic "mount_point" {
  #   for_each = var.offsite_backup_mount_points
  #   content {
  #     volume    = mount_point.value.volume
  #     path      = mount_point.value.path
  #     read_only = try(mount_point.value.read_only, true)
  #   }
  # }


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
