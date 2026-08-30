---
name: proxmox-bootstrap
description: Interactively bootstrap, configure, and provision a new Proxmox homelab cluster from Day-0. Use when the user asks to bootstrap the homelab, initialize the cluster, setup OpenTofu infrastructure, configure baseline secrets, or provision the core baseline services (AdGuard, Cloudflared, Uptime Kuma).
---

# Proxmox Cluster Bootstrapper

## Overview
This skill guides the sysadmin or agent through the initial Day-0 onboarding and provisioning of the Proxmox homelab infrastructure from within the `mgmt-devops` management workspace (CT 900). It discovers hypervisor hardware, generates secrets and `terraform.tfvars`, runs OpenTofu validation and application, and executes post-install hooks.

## When to Use
Use when:
- Initializing a freshly installed Proxmox cluster or single-node hypervisor;
- Running initial cluster onboarding after cloning the repository into `mgmt-devops`;
- Generating `tofu/terraform.tfvars` from `secrets.env` or 1Password;
- Provisioning the core baseline workloads (AdGuard Home, Cloudflared, Uptime Kuma).

Do **not** use for:
- Day-2 maintenance or rolling reboots (use `proxmox-maintenance`);
- Auditing cluster health or diagnosing bugs on existing containers (use `proxmox-cluster-health` or `proxmox-workload-debug`);
- Scaffolding new application workloads (use `proxmox-scaffold-app`).

## Core Process

### 1. Environment & Hardware Discovery
Inspect the local Proxmox environment to detect available nodes, storage pools, and network bridges:
```bash
# Discover active cluster nodes
pvesh get /nodes --output-format json 2>/dev/null || echo "Single node environment"

# Discover available storage pools (local-lvm, local-zfs, nfs)
pvesm status 2>/dev/null || true

# Discover network bridge configuration
ip route show default 2>/dev/null || true
```

### 2. Configure Secrets & Environment
Prompt the user or check for existing credentials in `secrets.env` or 1Password CLI (`op`):
1. **Proxmox API Credentials**: Host IP/FQDN, API token or root credentials.
2. **DNS & Networking**: Subnet CIDR, Gateway IP, Domain name.
3. **Ingress**: Cloudflare Tunnel Token (optional, for external zero-trust access).
4. **Topology**: Single-node (`enable_ha = false`) or Multi-node HA (`enable_ha = true`).

Generate OpenTofu variables and stack environment files:
```bash
./scripts/bootstrap-secrets.sh
```

### 3. OpenTofu Initialization & Planning
Initialize OpenTofu providers and verify the planned execution:
```bash
cd tofu
tofu init
tofu fmt -check
tofu validate
tofu plan
```
Present the execution plan to the user showing the baseline resources to be created (CT 501 AdGuard, CT 510 Cloudflared, CT 601 Monitoring).

### 4. Provision Core Infrastructure
Apply the declarative configuration:
```bash
cd tofu
tofu apply
```

### 5. Post-Provisioning Configuration Hooks
Execute post-install configuration scripts:
```bash
# 1. Setup AdGuard Home DNS
./scripts/install-adguard.sh

# 2. Setup Cloudflare Tunnel connector (if token provided)
./scripts/install-cloudflared.sh

# 3. Setup Uptime Kuma & Discord alerts
./scripts/setup-discord-alerts.sh
```

## Verification
Confirm the bootstrap is complete only when:
- [ ] `tofu/terraform.tfvars` exists and contains valid node and credential mappings.
- [ ] `tofu validate` returns exit code 0 with no syntax or type errors.
- [ ] Core containers are running:
  - AdGuard Home (CT 501) responds on port 53 (DNS) and port 3000/80 (Admin UI).
  - Monitoring / Uptime Kuma (CT 601) responds on port 3001.
  - Cloudflared (CT 510) tunnel status is active (if configured).
- [ ] The user is presented with an interactive summary table of all active endpoints and credentials.
