# OpenTofu Application Container Module (`tofu/modules/app-container`)

Standardized, reusable OpenTofu module for provisioning declarative, unprivileged LXC application containers on Proxmox VE with dynamic hypervisor node placement, deterministic MAC addressing, nested Docker execution, and dual-tier SSH access.

---

## 🎯 Key Architectural Features

1. **Dynamic Node Placement**:
   - Accepts `node_name = var.node_name` (defaulting to `var.app_node_name` / `tuxmox`, seamlessly overridable to `proxmox`).
   - Enables flexible cluster scheduling without rewriting HCL resource definitions.
2. **Unprivileged Nested Docker Isolation**:
   - `unprivileged = true` maps container root to host UID `100000+`, neutralizing container breakout vectors.
   - `nesting = true` provides containerized cgroup and namespace support for Docker Compose workloads.
3. **Deterministic Networking & Static DHCP**:
   - Assigns a deterministic MAC address (`bc:24:11:00:XX:YY`) to `eth0` attached to virtual bridge `vmbr0`.
   - Defaults to `ipv4_address = "dhcp"`, pairing with AdGuard Home static DHCP reservations.
4. **SSH Public-Key Security**:
   - Injects Management Workspace (`CT 900`) and cluster public keys into `/root/.ssh/authorized_keys` during container initialization for streamlined administrative access.

---

## 📦 Usage Example

```hcl
module "my_app_container" {
  source = "./modules/app-container"

  node_name   = var.app_node_name # Defaults to tuxmox, overridable to proxmox
  vm_id       = 701
  hostname    = "my-app"
  description = "Managed by OpenTofu | Production Application Stack"

  cores        = 2
  memory       = 2048
  swap         = 512
  disk_size    = 20
  disk_storage = "local-lvm"

  mac_address  = "bc:24:11:00:07:01"
  ipv4_address = "dhcp"

  ssh_public_keys = var.app_ssh_public_keys
}
```

---

## ⚙️ Inputs

| Name | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `node_name` | `string` | `"tuxmox"` | Proxmox node hosting container (`tuxmox` or `proxmox`). |
| `vm_id` | `number` | *required* | Unique Container ID (CTID). |
| `hostname` | `string` | *required* | Hostname for the container. |
| `description` | `string` | `"Managed by OpenTofu | Declarative Application Stack"` | Description / notes. |
| `tags` | `list(string)` | `["application", "docker", "unprivileged", "opentofu"]` | Resource tags in Proxmox. |
| `unprivileged` | `bool` | `true` | Unprivileged LXC mode. |
| `nesting` | `bool` | `true` | Enable nested Docker execution. |
| `cores` | `number` | `2` | CPU core count. |
| `memory` | `number` | `2048` | Dedicated RAM (MB). |
| `swap` | `number` | `512` | Swap space (MB). |
| `disk_storage` | `string` | `"local-lvm"` | Target storage pool. |
| `disk_size` | `number` | `20` | Root disk size (GB). |
| `template_file_id` | `string` | `"local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"` | OS template. |
| `network_bridge` | `string` | `"vmbr0"` | Host virtual bridge. |
| `mac_address` | `string` | *required* | Deterministic MAC address. |
| `ipv4_address` | `string` | `"dhcp"` | IPv4 address or "dhcp". |
| `ipv4_gateway` | `string` | `null` | Gateway address (if static). |
| `ssh_public_keys` | `list(string)` | `[]` | SSH public keys for root. |

---

## 📤 Outputs

| Name | Description |
| :--- | :--- |
| `container_id` | Assigned CTID. |
| `node` | Hypervisor node running container. |
| `hostname` | Container hostname. |
| `ip_addresses` | IP configuration. |
| `mac_address` | MAC address. |
| `unprivileged` | LXC isolation mode boolean. |
| `tags` | Tags assigned to container. |
