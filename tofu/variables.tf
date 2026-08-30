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
  default     = "node-1"
}

variable "enable_ha" {
  description = "Enable High Availability secondary containers (e.g. AdGuard secondary, Cloudflared secondary)"
  type        = bool
  default     = true
}

variable "secondary_node_name" {
  description = "Secondary Proxmox VE hypervisor node name for HA failover (optional for single-node)"
  type        = string
  default     = "node-2"
}

variable "default_disk_storage" {
  description = "Default storage pool for container root disks (e.g. local-lvm, local-zfs)"
  type        = string
  default     = "local-lvm"
}

variable "utility_node_name" {
  description = "The Proxmox node name for cluster management, DevOps, and lightweight workloads (Alias for primary_node_name)"
  type        = string
  default     = "node-1"
}

variable "utility_node_address" {
  description = "IP address or hostname of the utility/cluster lead node (accessible at pve.example.com)"
  type        = string
  default     = "10.0.0.10"
}

variable "compute_node_name" {
  description = "The Proxmox node name for compute/media workloads (Alias for secondary_node_name)"
  type        = string
  default     = "node-2"
}

variable "compute_node_address" {
  description = "IP address or hostname of the compute node"
  type        = string
  default     = "10.0.0.20"
}

variable "app_node_name" {
  description = "Default Proxmox hypervisor node for declarative production workload containers"
  type        = string
  default     = "node-2"
}

# ==============================================================================
# Cloudflared Tunnel HA LXC Variables (Primary - Node: node-1)
# ==============================================================================

variable "cloudflared_primary_ct_id" {
  description = "Container ID for Cloudflared Primary LXC"
  type        = number
  default     = 510
}

variable "cloudflared_primary_hostname" {
  description = "Hostname for Cloudflared Primary container"
  type        = string
  default     = "cloudflared-primary"
}

variable "cloudflared_primary_cores" {
  description = "Number of CPU cores allocated to Cloudflared Primary"
  type        = number
  default     = 1
}

variable "cloudflared_primary_memory" {
  description = "Dedicated RAM (MB) for Cloudflared Primary"
  type        = number
  default     = 512
}

variable "cloudflared_primary_swap" {
  description = "Swap space (MB) for Cloudflared Primary"
  type        = number
  default     = 256
}

variable "cloudflared_primary_disk_storage" {
  description = "Storage pool for the root disk"
  type        = string
  default     = "local-lvm"
}

variable "cloudflared_primary_disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 8
}

variable "cloudflared_primary_template_file_id" {
  description = "Proxmox OS template file ID"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "cloudflared_primary_network_bridge" {
  description = "Network bridge interface"
  type        = string
  default     = "vmbr0"
}

variable "cloudflared_primary_mac_address" {
  description = "MAC address for the network interface"
  type        = string
  default     = "bc:24:11:00:05:10"
}

variable "cloudflared_primary_ipv4_address" {
  description = "IPv4 address/CIDR or 'dhcp'"
  type        = string
  default     = "dhcp"
}

variable "cloudflared_primary_ipv4_gateway" {
  description = "IPv4 default gateway (leave null/empty if using DHCP)"
  type        = string
  default     = null
}

variable "cloudflared_primary_vlan_id" {
  description = "VLAN tag for the network interface (null if untagged)"
  type        = number
  default     = null
}

variable "cloudflared_primary_ssh_public_keys" {
  description = "List of SSH public keys to install into /root/.ssh/authorized_keys"
  type        = list(string)
  default     = []
}

variable "cloudflared_primary_unprivileged" {
  description = "Whether LXC is unprivileged. True for Cloudflared tunnel connectors"
  type        = bool
  default     = true
}

variable "cloudflared_primary_tags" {
  description = "Proxmox tags to apply to the Cloudflared Primary container"
  type        = list(string)
  default     = ["cloudflared", "ha-primary", "ingress", "tunnel", "opentofu"]
}

# ==============================================================================
# Cloudflared Tunnel HA LXC Variables (Secondary - Node: node-2)
# ==============================================================================

variable "cloudflared_secondary_ct_id" {
  description = "Container ID for Cloudflared Secondary LXC"
  type        = number
  default     = 511
}

variable "cloudflared_secondary_hostname" {
  description = "Hostname for Cloudflared Secondary container"
  type        = string
  default     = "cloudflared-secondary"
}

variable "cloudflared_secondary_cores" {
  description = "Number of CPU cores allocated to Cloudflared Secondary"
  type        = number
  default     = 1
}

variable "cloudflared_secondary_memory" {
  description = "Dedicated RAM (MB) for Cloudflared Secondary"
  type        = number
  default     = 512
}

variable "cloudflared_secondary_swap" {
  description = "Swap space (MB) for Cloudflared Secondary"
  type        = number
  default     = 256
}

variable "cloudflared_secondary_disk_storage" {
  description = "Storage pool for the root disk"
  type        = string
  default     = "local-lvm"
}

variable "cloudflared_secondary_disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 8
}

variable "cloudflared_secondary_template_file_id" {
  description = "Proxmox OS template file ID"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "cloudflared_secondary_network_bridge" {
  description = "Network bridge interface"
  type        = string
  default     = "vmbr0"
}

variable "cloudflared_secondary_mac_address" {
  description = "MAC address for the network interface"
  type        = string
  default     = "bc:24:11:00:05:11"
}

variable "cloudflared_secondary_ipv4_address" {
  description = "IPv4 address/CIDR or 'dhcp'"
  type        = string
  default     = "dhcp"
}

variable "cloudflared_secondary_ipv4_gateway" {
  description = "IPv4 default gateway (leave null/empty if using DHCP)"
  type        = string
  default     = null
}

variable "cloudflared_secondary_vlan_id" {
  description = "VLAN tag for the network interface (null if untagged)"
  type        = number
  default     = null
}

variable "cloudflared_secondary_ssh_public_keys" {
  description = "List of SSH public keys to install into /root/.ssh/authorized_keys"
  type        = list(string)
  default     = []
}

variable "cloudflared_secondary_unprivileged" {
  description = "Whether LXC is unprivileged. True for Cloudflared tunnel connectors"
  type        = bool
  default     = true
}

variable "cloudflared_secondary_tags" {
  description = "Proxmox tags to apply to the Cloudflared Secondary container"
  type        = list(string)
  default     = ["cloudflared", "ha-secondary", "ingress", "tunnel", "opentofu"]
}

# ==============================================================================
# AdGuard Home Primary LXC Variables (Node: node-1)
# ==============================================================================

variable "adguard_primary_ct_id" {
  description = "Container ID for AdGuard Primary LXC"
  type        = number
  default     = 501
}

variable "adguard_primary_hostname" {
  description = "Hostname for AdGuard Primary container"
  type        = string
  default     = "adguard-primary"
}

variable "adguard_primary_cores" {
  description = "Number of CPU cores allocated to AdGuard Primary"
  type        = number
  default     = 2
}

variable "adguard_primary_memory" {
  description = "Dedicated RAM (MB) for AdGuard Primary"
  type        = number
  default     = 1024
}

variable "adguard_primary_swap" {
  description = "Swap space (MB) for AdGuard Primary"
  type        = number
  default     = 512
}

variable "adguard_primary_disk_storage" {
  description = "Storage pool for the root disk"
  type        = string
  default     = "local-lvm"
}

variable "adguard_primary_disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 10
}

variable "adguard_primary_template_file_id" {
  description = "Proxmox OS template file ID"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "adguard_primary_network_bridge" {
  description = "Network bridge interface"
  type        = string
  default     = "vmbr0"
}

variable "adguard_primary_mac_address" {
  description = "MAC address for the network interface"
  type        = string
  default     = "bc:24:11:00:05:01"
}

variable "adguard_primary_ipv4_address" {
  description = "IPv4 address/CIDR (e.g. 10.0.0.201/24)"
  type        = string
  default     = "10.0.0.201/24"
}

variable "adguard_primary_ipv4_gateway" {
  description = "IPv4 default gateway"
  type        = string
  default     = "10.0.0.1"
}

variable "adguard_primary_vlan_id" {
  description = "VLAN tag for the network interface (null if untagged)"
  type        = number
  default     = null
}

variable "adguard_primary_ssh_public_keys" {
  description = "List of SSH public keys to install into /root/.ssh/authorized_keys"
  type        = list(string)
  default     = []
}

variable "adguard_primary_unprivileged" {
  description = "Whether LXC is unprivileged. Recommended false for privileged mode"
  type        = bool
  default     = false
}

variable "adguard_primary_tags" {
  description = "Proxmox tags to apply to the AdGuard Primary container"
  type        = list(string)
  default     = ["dns", "adguard", "ha-primary", "dhcp", "opentofu"]
}

# ==============================================================================
# AdGuard Home Secondary LXC Variables (Node: node-2)
# ==============================================================================

variable "adguard_secondary_ct_id" {
  description = "Container ID for AdGuard Secondary LXC"
  type        = number
  default     = 502
}

variable "adguard_secondary_hostname" {
  description = "Hostname for AdGuard Secondary container"
  type        = string
  default     = "adguard-secondary"
}

variable "adguard_secondary_cores" {
  description = "Number of CPU cores allocated to AdGuard Secondary"
  type        = number
  default     = 2
}

variable "adguard_secondary_memory" {
  description = "Dedicated RAM (MB) for AdGuard Secondary"
  type        = number
  default     = 1024
}

variable "adguard_secondary_swap" {
  description = "Swap space (MB) for AdGuard Secondary"
  type        = number
  default     = 512
}

variable "adguard_secondary_disk_storage" {
  description = "Storage pool for the root disk"
  type        = string
  default     = "local-lvm"
}

variable "adguard_secondary_disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 10
}

variable "adguard_secondary_template_file_id" {
  description = "Proxmox OS template file ID"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "adguard_secondary_network_bridge" {
  description = "Network bridge interface"
  type        = string
  default     = "vmbr0"
}

variable "adguard_secondary_mac_address" {
  description = "MAC address for the network interface"
  type        = string
  default     = "bc:24:11:00:05:02"
}

variable "adguard_secondary_ipv4_address" {
  description = "IPv4 address/CIDR (e.g. 10.0.0.202/24)"
  type        = string
  default     = "10.0.0.202/24"
}

variable "adguard_secondary_ipv4_gateway" {
  description = "IPv4 default gateway"
  type        = string
  default     = "10.0.0.1"
}

variable "adguard_secondary_vlan_id" {
  description = "VLAN tag for the network interface (null if untagged)"
  type        = number
  default     = null
}

variable "adguard_secondary_ssh_public_keys" {
  description = "List of SSH public keys to install into /root/.ssh/authorized_keys"
  type        = list(string)
  default     = []
}

variable "adguard_secondary_unprivileged" {
  description = "Whether LXC is unprivileged. Recommended false for privileged mode"
  type        = bool
  default     = false
}

variable "adguard_secondary_tags" {
  description = "Proxmox tags to apply to the AdGuard Secondary container"
  type        = list(string)
  default     = ["dns", "adguard", "ha-secondary", "dhcp", "opentofu"]
}

variable "adguard_dns_servers" {
  description = "DNS servers to configure for AdGuard Home LXC containers"
  type        = list(string)
  default     = ["10.0.0.101"]
}

# ==============================================================================
# Monitoring (Uptime Kuma) LXC Variables
# ==============================================================================

variable "monitoring_ct_id" {
  description = "Container ID for Monitoring LXC (Uptime Kuma)"
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
  default     = 1024
}

variable "monitoring_swap" {
  description = "Swap space (MB) for Monitoring"
  type        = number
  default     = 512
}

variable "monitoring_disk_storage" {
  description = "Storage pool for the root disk"
  type        = string
  default     = "local-lvm"
}

variable "monitoring_disk_size" {
  description = "Root disk size in GB"
  type        = number
  default     = 16
}

variable "monitoring_template_file_id" {
  description = "Proxmox OS template file ID (e.g. local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst)"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "monitoring_network_bridge" {
  description = "Network bridge interface"
  type        = string
  default     = "vmbr0"
}

variable "monitoring_mac_address" {
  description = "MAC address for the network interface"
  type        = string
  default     = "bc:24:11:00:06:01"
}

variable "monitoring_ipv4_address" {
  description = "IPv4 address/CIDR or 'dhcp'"
  type        = string
  default     = "dhcp"
}

variable "monitoring_ipv4_gateway" {
  description = "IPv4 default gateway (leave null/empty if using DHCP)"
  type        = string
  default     = null
}

variable "monitoring_vlan_id" {
  description = "VLAN tag for the network interface (null if untagged)"
  type        = number
  default     = null
}

variable "monitoring_ssh_public_keys" {
  description = "List of SSH public keys to install into /root/.ssh/authorized_keys"
  type        = list(string)
  default     = []
}

variable "monitoring_unprivileged" {
  description = "Whether LXC is unprivileged. False (privileged) for Docker nesting"
  type        = bool
  default     = false
}

variable "monitoring_tags" {
  description = "Proxmox tags to apply to the Monitoring container"
  type        = list(string)
  default     = ["monitoring", "uptime-kuma", "opentofu"]
}

# ==============================================================================
# Declarative Application Containers (app-container module)
# ==============================================================================

variable "app_ssh_public_keys" {
  description = "List of SSH public keys to install into /root/.ssh/authorized_keys for application containers"
  type        = list(string)
  default     = []
}
