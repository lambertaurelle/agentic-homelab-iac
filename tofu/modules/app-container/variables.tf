# ==============================================================================
# Declarative Application LXC Container Module - Variables
# ==============================================================================

variable "node_name" {
  description = "The Proxmox hypervisor node on which to create the container (e.g. tuxmox or proxmox)"
  type        = string
  default     = "tuxmox"
}

variable "vm_id" {
  description = "The unique Container ID (CTID) within the Proxmox cluster"
  type        = number
}

variable "hostname" {
  description = "Hostname for the application container"
  type        = string
}

variable "description" {
  description = "Description / notes for the container in Proxmox VE"
  type        = string
  default     = "Managed by OpenTofu | Declarative Application Stack"
}

variable "tags" {
  description = "Tags to assign to the LXC container in Proxmox"
  type        = list(string)
  default     = ["application", "docker", "unprivileged", "opentofu"]
}

variable "unprivileged" {
  description = "Whether the container runs in unprivileged LXC mode (UID shifted 100000+)"
  type        = bool
  default     = true
}

variable "started" {
  description = "Whether the container should be started immediately after creation"
  type        = bool
  default     = true
}

variable "start_on_boot" {
  description = "Whether the container should start automatically on hypervisor boot"
  type        = bool
  default     = true
}

variable "startup_order" {
  description = "Startup boot priority order (1 = core network/DNS, 2 = ingress, 3 = applications)"
  type        = number
  default     = 3
}

variable "startup_up_delay" {
  description = "Delay in seconds before starting the next container in the boot sequence"
  type        = number
  default     = 10
}

variable "nesting" {
  description = "Enable nested virtualization features for Docker container runtime execution"
  type        = bool
  default     = true
}

variable "cores" {
  description = "Number of CPU cores allocated to the container"
  type        = number
  default     = 2
}

variable "memory" {
  description = "Dedicated RAM allocated to the container in Megabytes (MB)"
  type        = number
  default     = 2048
}

variable "swap" {
  description = "Swap memory space in Megabytes (MB)"
  type        = number
  default     = 512
}

variable "disk_storage" {
  description = "Target storage pool for the root volume disk (e.g. local-lvm)"
  type        = string
  default     = "local-lvm"
}

variable "disk_size" {
  description = "Root disk size in Gigabytes (GB)"
  type        = number
  default     = 20
}

variable "template_file_id" {
  description = "OS template file identifier on the Proxmox storage"
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "os_type" {
  description = "Operating system type for container initialization"
  type        = string
  default     = "debian"
}

variable "network_bridge" {
  description = "Network bridge interface on the Proxmox host"
  type        = string
  default     = "vmbr0"
}

variable "mac_address" {
  description = "Deterministic MAC address for the container network interface (format: bc:24:11:00:XX:YY)"
  type        = string

  validation {
    condition     = can(regex("^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", var.mac_address))
    error_message = "mac_address must be a valid MAC address format (e.g. bc:24:11:00:07:01)."
  }
}

variable "ipv4_address" {
  description = "IPv4 address with CIDR mask (e.g. '10.0.0.X/24') or 'dhcp'"
  type        = string
  default     = "dhcp"

  validation {
    condition     = var.ipv4_address == "dhcp" || can(cidrhost(var.ipv4_address, 0))
    error_message = "ipv4_address must be 'dhcp' or a valid IPv4 CIDR string (e.g. 10.0.0.71/24)."
  }
}

variable "ipv4_gateway" {
  description = "Default IPv4 gateway address (required if static IP is used; null for DHCP)"
  type        = string
  default     = null
}

variable "vlan_id" {
  description = "VLAN tag ID if container is connected to a segmented VLAN"
  type        = number
  default     = null
}

variable "dns_servers" {
  description = "Custom DNS servers for container initialization"
  type        = list(string)
  default     = null
}

variable "ssh_public_keys" {
  description = "List of SSH public keys to install into /root/.ssh/authorized_keys during container creation"
  type        = list(string)
  default     = []
}

variable "mount_points" {
  description = "Optional host bind mount points to pass through into the container"
  type = list(object({
    volume    = string
    path      = string
    read_only = optional(bool, false)
  }))
  default = []
}

variable "device_passthroughs" {
  description = "Optional host device nodes (e.g. /dev/dri/renderD128) to pass through"
  type = list(object({
    path = string
  }))
  default = []
}
