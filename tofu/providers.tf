terraform {
  required_version = ">= 1.6.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.68"
    }
  }
}

provider "proxmox" {
  endpoint = var.proxmox_endpoint
  insecure = var.proxmox_insecure

  # Authentication via API Token (Preferred) or Username/Password
  api_token = var.proxmox_api_token != "" ? var.proxmox_api_token : null
  username  = var.proxmox_api_token == "" ? var.proxmox_username : null
  password  = var.proxmox_api_token == "" ? var.proxmox_password : null

  # Optional SSH configuration for operations requiring node access
  dynamic "ssh" {
    for_each = var.proxmox_ssh_enabled ? [1] : []
    content {
      agent    = var.proxmox_ssh_agent
      username = var.proxmox_ssh_username
      node {
        name    = var.utility_node_name
        address = var.utility_node_address
      }
      node {
        name    = var.compute_node_name
        address = var.compute_node_address
      }
    }
  }
}
