# ==============================================================================
# Proxmox VE Connection Variables
# ==============================================================================

variable "proxmox_endpoint" {
  description = "The Proxmox VE API endpoint URL (e.g. https://pve.example.com:8006/ or https://10.0.0.10:8006/)"
  type        = string
}

variable "proxmox_api_token" {
  description = "Proxmox API token in format: USER@REALM!TOKENID=UUID"
  type        = string
  default     = ""
  sensitive   = true
}

variable "proxmox_username" {
  description = "Proxmox username (used if api_token is empty)"
  type        = string
  default     = "root@pam"
}

variable "proxmox_password" {
  description = "Proxmox password (used if api_token is empty)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Disable TLS verification for self-signed certificates"
  type        = bool
  default     = true
}

variable "proxmox_ssh_enabled" {
  description = "Enable SSH configuration block for the provider"
  type        = bool
  default     = false
}

variable "proxmox_ssh_agent" {
  description = "Whether to use SSH agent for SSH connections"
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH username for Proxmox node access"
  type        = string
  default     = "root"
}

# ==============================================================================
# Cluster & Node Variables (Node & Storage Agnostic)
# ==============================================================================

variable "primary_node_name" {
  description = "Primary Proxmox VE hypervisor node name (works for single-node and multi-node setups)"
  type        = string
  default     = "pve"
}

variable "enable_ha" {
  description = "Enable High Availability secondary containers (e.g. AdGuard secondary, Cloudflared secondary)"
  type        = bool
  default     = false
}

variable "secondary_node_name" {
  description = "Secondary Proxmox VE hypervisor node name for HA failover (optional for single-node)"
  type        = string
  default     = ""
}

variable "default_disk_storage" {
  description = "Default storage pool for container root disks (e.g. local-lvm, local-zfs)"
  type        = string
  default     = "local-lvm"
}

variable "utility_node_name" {
  description = "Alias for primary_node_name"
  type        = string
  default     = "pve"
}

variable "compute_node_name" {
  description = "Alias for secondary_node_name"
  type        = string
  default     = ""
}

variable "app_node_name" {
  description = "Default Proxmox hypervisor node for declarative production workload containers"
  type        = string
  default     = "pve"
}

# ==============================================================================
# AdGuard Home Core Variables
# ==============================================================================

variable "adguard_dns_servers" {
  description = "Upstream bootstrap DNS servers for AdGuard containers during initial provisioning"
  type        = list(string)
  default     = ["1.1.1.1", "1.0.0.1"]
}

variable "adguard_primary_ct_id" {
  description = "Container ID for Primary AdGuard Home LXC"
  type        = number
  default     = 501
}

variable "adguard_primary_hostname" {
  description = "Hostname for Primary AdGuard container"
  type        = string
  default     = "adguard-primary"
}

variable "adguard_primary_cores" {
  description = "Number of CPU cores allocated to Primary AdGuard"
  type        = number
  default     = 2
}

variable "adguard_primary_memory" {
  description = "Dedicated RAM (MB) for Primary AdGuard"
  type        = number
  default     = 1024
}

variable "adguard_primary_swap" {
  description = "Swap space (MB) for Primary AdGuard"
  type        = number
  default     = 512
}

variable "adguard_primary_disk_storage" {
  description = "Storage pool for Primary AdGuard root disk"
  type        = string
  default     = "local-lvm"
}

variable "adguard_primary_disk_size" {
  description = "Root disk size in GB for Primary AdGuard"
  type        = number
  default     = 8
}

variable "adguard_primary_template_file_id" {
  description = "OS template file ID for Primary AdGuard"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "adguard_primary_network_bridge" {
  description = "Network bridge for Primary AdGuard"
  type        = string
  default     = "vmbr0"
}

variable "adguard_primary_mac_address" {
  description = "MAC address for Primary AdGuard"
  type        = string
  default     = "bc:24:11:00:05:01"
}

variable "adguard_primary_ipv4_address" {
  description = "IPv4 address/CIDR for Primary AdGuard (e.g. 10.0.0.201/24 or dhcp)"
  type        = string
  default     = "dhcp"
}

variable "adguard_primary_ipv4_gateway" {
  description = "IPv4 default gateway for Primary AdGuard"
  type        = string
  default     = null
}

variable "adguard_primary_vlan_id" {
  description = "VLAN tag for Primary AdGuard"
  type        = number
  default     = null
}

variable "adguard_primary_ssh_public_keys" {
  description = "SSH public keys for Primary AdGuard"
  type        = list(string)
  default     = []
}

variable "adguard_primary_unprivileged" {
  description = "Unprivileged mode for Primary AdGuard"
  type        = bool
  default     = false
}

variable "adguard_primary_tags" {
  description = "Tags for Primary AdGuard"
  type        = list(string)
  default     = ["dns", "dhcp", "core", "adguard", "primary"]
}

# ------------------------------------------------------------------------------
# AdGuard Home Secondary (HA Standby) Variables
# ------------------------------------------------------------------------------

variable "adguard_secondary_ct_id" {
  description = "Container ID for Secondary AdGuard Home LXC"
  type        = number
  default     = 502
}

variable "adguard_secondary_hostname" {
  description = "Hostname for Secondary AdGuard container"
  type        = string
  default     = "adguard-secondary"
}

variable "adguard_secondary_cores" {
  description = "Number of CPU cores allocated to Secondary AdGuard"
  type        = number
  default     = 2
}

variable "adguard_secondary_memory" {
  description = "Dedicated RAM (MB) for Secondary AdGuard"
  type        = number
  default     = 1024
}

variable "adguard_secondary_swap" {
  description = "Swap space (MB) for Secondary AdGuard"
  type        = number
  default     = 512
}

variable "adguard_secondary_disk_storage" {
  description = "Storage pool for Secondary AdGuard root disk"
  type        = string
  default     = "local-lvm"
}

variable "adguard_secondary_disk_size" {
  description = "Root disk size in GB for Secondary AdGuard"
  type        = number
  default     = 8
}

variable "adguard_secondary_template_file_id" {
  description = "OS template file ID for Secondary AdGuard"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "adguard_secondary_network_bridge" {
  description = "Network bridge for Secondary AdGuard"
  type        = string
  default     = "vmbr0"
}

variable "adguard_secondary_mac_address" {
  description = "MAC address for Secondary AdGuard"
  type        = string
  default     = "bc:24:11:00:05:02"
}

variable "adguard_secondary_ipv4_address" {
  description = "IPv4 address/CIDR for Secondary AdGuard"
  type        = string
  default     = "dhcp"
}

variable "adguard_secondary_ipv4_gateway" {
  description = "IPv4 default gateway for Secondary AdGuard"
  type        = string
  default     = null
}

variable "adguard_secondary_vlan_id" {
  description = "VLAN tag for Secondary AdGuard"
  type        = number
  default     = null
}

variable "adguard_secondary_ssh_public_keys" {
  description = "SSH public keys for Secondary AdGuard"
  type        = list(string)
  default     = []
}

variable "adguard_secondary_unprivileged" {
  description = "Unprivileged mode for Secondary AdGuard"
  type        = bool
  default     = false
}

variable "adguard_secondary_tags" {
  description = "Tags for Secondary AdGuard"
  type        = list(string)
  default     = ["dns", "dhcp", "core", "adguard", "secondary"]
}

# ==============================================================================
# Cloudflared Core Variables
# ==============================================================================

variable "cloudflared_primary_ct_id" {
  description = "Container ID for Primary Cloudflare Tunnel LXC"
  type        = number
  default     = 510
}

variable "cloudflared_primary_hostname" {
  description = "Hostname for Primary Cloudflare Tunnel container"
  type        = string
  default     = "cloudflared-primary"
}

variable "cloudflared_primary_cores" {
  description = "Number of CPU cores allocated to Primary Cloudflared"
  type        = number
  default     = 1
}

variable "cloudflared_primary_memory" {
  description = "Dedicated RAM (MB) for Primary Cloudflared"
  type        = number
  default     = 512
}

variable "cloudflared_primary_swap" {
  description = "Swap space (MB) for Primary Cloudflared"
  type        = number
  default     = 256
}

variable "cloudflared_primary_disk_storage" {
  description = "Storage pool for Primary Cloudflared root disk"
  type        = string
  default     = "local-lvm"
}

variable "cloudflared_primary_disk_size" {
  description = "Root disk size in GB for Primary Cloudflared"
  type        = number
  default     = 4
}

variable "cloudflared_primary_template_file_id" {
  description = "OS template file ID for Primary Cloudflared"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "cloudflared_primary_network_bridge" {
  description = "Network bridge for Primary Cloudflared"
  type        = string
  default     = "vmbr0"
}

variable "cloudflared_primary_mac_address" {
  description = "MAC address for Primary Cloudflared"
  type        = string
  default     = "bc:24:11:00:05:10"
}

variable "cloudflared_primary_ipv4_address" {
  description = "IPv4 address/CIDR for Primary Cloudflared"
  type        = string
  default     = "dhcp"
}

variable "cloudflared_primary_ipv4_gateway" {
  description = "IPv4 default gateway for Primary Cloudflared"
  type        = string
  default     = null
}

variable "cloudflared_primary_vlan_id" {
  description = "VLAN tag for Primary Cloudflared"
  type        = number
  default     = null
}

variable "cloudflared_primary_ssh_public_keys" {
  description = "SSH public keys for Primary Cloudflared"
  type        = list(string)
  default     = []
}

variable "cloudflared_primary_unprivileged" {
  description = "Unprivileged mode for Primary Cloudflared"
  type        = bool
  default     = true
}

variable "cloudflared_primary_tags" {
  description = "Tags for Primary Cloudflared"
  type        = list(string)
  default     = ["ingress", "cloudflare", "core", "primary"]
}

# ------------------------------------------------------------------------------
# Cloudflared Secondary (HA Connector) Variables
# ------------------------------------------------------------------------------

variable "cloudflared_secondary_ct_id" {
  description = "Container ID for Secondary Cloudflare Tunnel LXC"
  type        = number
  default     = 511
}

variable "cloudflared_secondary_hostname" {
  description = "Hostname for Secondary Cloudflare Tunnel container"
  type        = string
  default     = "cloudflared-secondary"
}

variable "cloudflared_secondary_cores" {
  description = "Number of CPU cores allocated to Secondary Cloudflared"
  type        = number
  default     = 1
}

variable "cloudflared_secondary_memory" {
  description = "Dedicated RAM (MB) for Secondary Cloudflared"
  type        = number
  default     = 512
}

variable "cloudflared_secondary_swap" {
  description = "Swap space (MB) for Secondary Cloudflared"
  type        = number
  default     = 256
}

variable "cloudflared_secondary_disk_storage" {
  description = "Storage pool for Secondary Cloudflared root disk"
  type        = string
  default     = "local-lvm"
}

variable "cloudflared_secondary_disk_size" {
  description = "Root disk size in GB for Secondary Cloudflared"
  type        = number
  default     = 4
}

variable "cloudflared_secondary_template_file_id" {
  description = "OS template file ID for Secondary Cloudflared"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "cloudflared_secondary_network_bridge" {
  description = "Network bridge for Secondary Cloudflared"
  type        = string
  default     = "vmbr0"
}

variable "cloudflared_secondary_mac_address" {
  description = "MAC address for Secondary Cloudflared"
  type        = string
  default     = "bc:24:11:00:05:11"
}

variable "cloudflared_secondary_ipv4_address" {
  description = "IPv4 address/CIDR for Secondary Cloudflared"
  type        = string
  default     = "dhcp"
}

variable "cloudflared_secondary_ipv4_gateway" {
  description = "IPv4 default gateway for Secondary Cloudflared"
  type        = string
  default     = null
}

variable "cloudflared_secondary_vlan_id" {
  description = "VLAN tag for Secondary Cloudflared"
  type        = number
  default     = null
}

variable "cloudflared_secondary_ssh_public_keys" {
  description = "SSH public keys for Secondary Cloudflared"
  type        = list(string)
  default     = []
}

variable "cloudflared_secondary_unprivileged" {
  description = "Unprivileged mode for Secondary Cloudflared"
  type        = bool
  default     = true
}

variable "cloudflared_secondary_tags" {
  description = "Tags for Secondary Cloudflared"
  type        = list(string)
  default     = ["ingress", "cloudflare", "core", "secondary"]
}

# ==============================================================================
# Monitoring (Uptime Kuma) Core Variables
# ==============================================================================

variable "monitoring_ct_id" {
  description = "Container ID for Monitoring LXC"
  type        = number
  default     = 601
}

variable "monitoring_hostname" {
  description = "Hostname for Monitoring container"
  type        = string
  default     = "monitoring"
}

variable "monitoring_cores" {
  description = "Number of CPU cores allocated to Monitoring"
  type        = number
  default     = 2
}

variable "monitoring_memory" {
  description = "Dedicated RAM (MB) for Monitoring"
  type        = number
  default     = 2048
}

variable "monitoring_swap" {
  description = "Swap space (MB) for Monitoring"
  type        = number
  default     = 512
}

variable "monitoring_disk_storage" {
  description = "Storage pool for Monitoring root disk"
  type        = string
  default     = "local-lvm"
}

variable "monitoring_disk_size" {
  description = "Root disk size in GB for Monitoring"
  type        = number
  default     = 10
}

variable "monitoring_template_file_id" {
  description = "OS template file ID for Monitoring"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "monitoring_network_bridge" {
  description = "Network bridge for Monitoring"
  type        = string
  default     = "vmbr0"
}

variable "monitoring_mac_address" {
  description = "MAC address for Monitoring"
  type        = string
  default     = "bc:24:11:00:06:01"
}

variable "monitoring_ipv4_address" {
  description = "IPv4 address/CIDR for Monitoring"
  type        = string
  default     = "dhcp"
}

variable "monitoring_ipv4_gateway" {
  description = "IPv4 default gateway for Monitoring"
  type        = string
  default     = null
}

variable "monitoring_vlan_id" {
  description = "VLAN tag for Monitoring"
  type        = number
  default     = null
}

variable "monitoring_ssh_public_keys" {
  description = "SSH public keys for Monitoring"
  type        = list(string)
  default     = []
}

variable "monitoring_unprivileged" {
  description = "Unprivileged mode for Monitoring"
  type        = bool
  default     = false
}

variable "monitoring_tags" {
  description = "Tags for Monitoring"
  type        = list(string)
  default     = ["monitoring", "uptime-kuma", "core", "docker"]
}

# ==============================================================================
# General Workload / Application Scaffolding Defaults
# ==============================================================================

variable "app_ssh_public_keys" {
  description = "Default SSH public keys for new application containers"
  type        = list(string)
  default     = []
}
