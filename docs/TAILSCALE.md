# Tailscale Subnet Router & SSH Bastion Guide

This document describes how to deploy, configure, and maintain the **Tailscale Subnet Router & SSH Bastion (CT 520)** on Proxmox VE.

---

## 1. Overview

| Attribute | Specification |
| :--- | :--- |
| **Container ID** | `520` |
| **Target Node** | `var.utility_node_name` (`node-1`) |
| **LXC Mode** | Unprivileged (`unprivileged = true`) with `/dev/net/tun` character device passthrough |
| **OS Template** | Debian 12 (Bookworm) Standard |
| **Capabilities** | - Subnet Router (advertises LAN subnet e.g. `10.0.0.0/24` or `192.168.1.0/24`)<br>- Tailscale SSH Server (secure, zero-trust SSH access from any device in your Tailnet)<br>- Kernel IP forwarding (IPv4 and IPv6) with UDP GRO network acceleration |

---

## 2. Configuration & Activation

Tailscale is an **opt-in baseline workload** in the generic starter stack.

### 2.1 Enable via OpenTofu

In `secrets.env` (or `tofu/terraform.tfvars`):
```dotenv
# Enable Tailscale Subnet Router
ENABLE_TAILSCALE="true"
TAILSCALE_HOSTNAME="tailscale"
TAILSCALE_ROUTES="10.0.0.0/24"

# Optional: Reusable/Ephemeral Auth Key from Tailscale Admin Console (for headless zero-touch registration)
# If left empty, an interactive login URL will be printed on first install.
TAILSCALE_AUTH_KEY=""
```

Run secrets bootstrap and apply OpenTofu:
```bash
./scripts/bootstrap-secrets.sh
cd tofu
tofu plan
tofu apply
```

### 2.2 Provisioning Tailscale Inside CT 520

Run the automated orchestrator from `mgmt-devops` (CT 900) or hypervisor:
```bash
# Automated install & interactive registration
./scripts/install-tailscale.sh install

# Or with explicit auth key and subnet routes:
./scripts/install-tailscale.sh install --authkey "tskey-auth-..." --routes "10.0.0.0/24"
```

The script will:
1. Verify `/dev/net/tun` passthrough in `/etc/pve/lxc/520.conf` on the target hypervisor node.
2. Push the installer payload into CT 520.
3. Configure `sysctl` for packet forwarding (`net.ipv4.ip_forward = 1` and `net.ipv6.conf.all.forwarding = 1`).
4. Apply Linux 6.x kernel UDP GRO acceleration (`ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off`).
5. Install the official Debian 12 `tailscale` package and enable the `tailscaled` daemon.
6. Register the node with Tailscale and print the browser authorization URL (if `TAILSCALE_AUTH_KEY` is not provided).

---

## 3. Tailscale Admin Console Approval

After authorizing the node:
1. Navigate to the **Tailscale Admin Console** -> **Machines**.
2. Locate the node named `tailscale` (or custom `TAILSCALE_HOSTNAME`).
3. Click the **...** menu -> **Edit route settings**.
4. Check the box to approve your advertised subnet routes (e.g., `10.0.0.0/24`).
5. (Optional) Under **Machine settings**, disable key expiry for long-term uninterrupted homelab routing.

---

## 4. Verification & Operational Commands

Check Tailscale status at any time:
```bash
# Query status from orchestrator
./scripts/install-tailscale.sh status

# Or directly via pve-exec
./scripts/pve-exec.sh node-1 "pct exec 520 -- tailscale status"
```

Verify IP forwarding:
```bash
./scripts/pve-exec.sh node-1 "pct exec 520 -- sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding"
```

---

## 5. Disaster Recovery & Node Relocation

When restoring CT 520 from a Proxmox VZDump backup via `./scripts/restore-all-lxc.sh`:
- The restoration engine automatically injects the `/dev/net/tun` cgroup permissions and mount entry into `/etc/pve/lxc/520.conf` prior to starting the container.
- Tailscale identity and state reside in `/var/lib/tailscale/` inside the container disk image, so the node preserves its Tailscale IP and cryptographic identity after restore.
