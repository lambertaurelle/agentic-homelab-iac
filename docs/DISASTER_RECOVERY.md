# Homelab Disaster Recovery & Restoration Runbook

Comprehensive Disaster Recovery (DR) runbook for restoring homelab services, individual containers, database engines, and full bare-metal rebuilds from OpenTofu IaC, 1Password secrets, and Synology NAS snapshots.

---

## 🎯 Recovery Objectives & Scenarios Overview

| Objective | Target Metric | Description |
| :--- | :--- | :--- |
| **RTO (Recovery Time Objective)** | **< 5 minutes** | Individual container restoration from Synology NAS VZDump snapshot. |
| **RTO (Bare-Metal Cluster)** | **< 30 minutes** | Complete cluster rebuild from bare metal using OpenTofu + 1Password secrets. |
| **RPO (Recovery Point Objective)** | **< 24 hours** | Maximum snapshot age (daily 03:00 AM backups); 0 data loss for NAS-mounted media and database volumes. |

```mermaid
flowchart TD
    Disaster(["Disaster Occurs"]) --> Assess{"Assess Failure Scope"}

    Assess -->|"LXC Corrupted / Deleted"| ScenarioA["Scenario A: Rapid NAS Snapshot Restore"]
    Assess -->|"Hardware / Storage Wipe"| ScenarioB["Scenario B: Bare-Metal OpenTofu Rebuild"]
    Assess -->|"Specific DB Corrupted"| ScenarioC["Granular Database Recovery"]
    Assess -->|"Total Cluster Down & No DNS"| ScenarioD["Emergency DNS Bypass"]

    ScenarioA --> RunRestoreScript["Run scripts/restore-all-lxc.sh"]
    RunRestoreScript --> VerifyA["Verify Services & Run scripts/scan-security.sh"]

    ScenarioB --> BootstrapSecrets["eval $(op signin) -> homelab-secrets.env -> bootstrap-secrets.sh"]
    BootstrapSecrets --> TofuApply["tofu init && tofu apply"]
    TofuApply --> InstallScripts["Run Stack Installer Scripts"]
    InstallScripts --> VerifyB["Run scripts/scan-security.sh -> Full Cluster Operational"]

    ScenarioC --> DBRestore["PostgreSQL VectorChord & SQLite Recovery"]
    ScenarioD --> RouterDNS["Override Router DHCP DNS to 9.9.9.9"]
```

---

## 📋 Cluster Architecture & Recovery Blueprint

The recovery procedures in this runbook leverage deterministic container allocations, automated VZDump snapshots to centralized backup storage (e.g. NFS/SMB/PBS storage pool), and declarative OpenTofu infrastructure.

> 💡 **Instance-Specific Inventory & Storage Pools**: For personal node names, static IP assignments, and backup export paths, refer to the [Instance Documentation Overlay (`docs/instance/`)](instance/):
> - [Container Inventory & Deterministic Allocations](instance/INVENTORY.md)
> - [Storage Mounts & VZDump Backup Schedules](instance/STORAGE_AND_BACKUPS.md)

---

## ⚡ Scenario A: Rapid Restore from Snapshots (< 5 Min)

All containers are backed up daily with `zstd` compression to the configured backup storage pool (e.g. `syno-backup` or `local-backup` mounted at `/mnt/pve/<storage>/dump`).

### 1. Discover Available Backups
From Management Workspace (`mgmt-devops`, CT 900) or either Proxmox hypervisor node (`node-1` / `node-2`):

```bash
/root/homelab-iac/scripts/restore-all-lxc.sh --list
```

*Output displays CTID, container name, timestamp, archive size, and filename.*

### 2. Restore a Single Container
To restore an individual corrupted container (e.g. CT 501 AdGuard or CT 601 Monitoring):

```bash
# Interactive mode (prompts for confirmation)
/root/homelab-iac/scripts/restore-all-lxc.sh 501

# Non-interactive / Force mode (auto-confirms and starts container)
/root/homelab-iac/scripts/restore-all-lxc.sh 501 --yes

# Restore to custom storage pool if needed
/root/homelab-iac/scripts/restore-all-lxc.sh 601 --storage local-lvm --yes
```

### 3. Restore All Containers (Cluster-Wide Rapid Recovery)
To restore all containers across both nodes (Utility Node `node-1` and Compute Node `node-2`) in a single command:

```bash
/root/homelab-iac/scripts/restore-all-lxc.sh --all --yes
```

### What the restoration script handles automatically:
1. Detects whether the container already exists and checks if it is running.
2. Stops running containers gracefully before restoration.
3. Automatically routes the `pct restore` command to the correct cluster node (Utility Node `node-1` vs Compute Node `node-2`).
4. Re-creates the container rootfs, restores all configuration files, and starts the container.
5. Performs post-restore health verification.

### 4. Post-Restoration Security & Configuration Verification
Immediately after container restoration, run the unified security scanner to verify zero configuration drift, correct privilege boundaries, and absence of exposed credentials:

```bash
/root/homelab-iac/scripts/scan-security.sh
```

**Verification Checklist:**
- **Zero Configuration Drift**: Ensures container privileges (`unprivileged`), capabilities (`CAP_NET_ADMIN`), and bind mounts match declarative OpenTofu policies.
- **Secret Isolation**: Confirms restored `.env` files retain restrictive permissions (`chmod 600`) and no credentials leaked into git tracking.
- **Port Exposure Validation**: Confirms no unauthorized host ports were opened outside registered exceptions ([`docs/SECURITY_EXCEPTIONS.md`](SECURITY_EXCEPTIONS.md)).

---

## 🏗 Scenario B: Total Bare-Metal Rebuild (IaC + 1Password)

Use this scenario if both hypervisors suffer catastrophic drive failure or the entire cluster is wiped.

### Step 1: Base Hypervisor Setup & Cluster Initialization
1. Install Proxmox VE 8.x (Debian 12 Bookworm) on both hardware nodes:
   - Node 1: Utility Node `node-1` (IP: `10.0.0.10/24`, Gateway: `10.0.0.1`)
   - Node 2: Compute Node `node-2` (IP: `10.0.0.20/24`, Gateway: `10.0.0.1`)
2. On Node 1 (Utility Node `node-1`), create the Proxmox cluster:
   ```bash
   pvecm create homelab-cluster
   ```
3. On Node 2 (Compute Node `node-2`), join the cluster:
   ```bash
   pvecm add 10.0.0.10
   ```
4. Verify cluster quorum:
   ```bash
   pvecm status
   ```

### Step 2: Bootstrap Secrets from 1Password & GitHub CLI
1. Clone repository to Management Workspace (`mgmt-devops`) or Utility Node (`node-1`):
   ```bash
   git clone https://github.com/<your-username>/homelab-iac.git /root/homelab-iac
   cd /root/homelab-iac
   ```
2. Authenticate and retrieve secrets via 1Password CLI (`op`) and GitHub CLI (`gh`):
   ```bash
   # 1. Authenticate with 1Password CLI & GitHub CLI
   eval $(op signin)
   gh auth status

   # 2. Retrieve homelab-secrets.env directly from 1Password vault item:
   op read "op://Private/Homelab Master Secrets/notesPlain" > homelab-secrets.env
   chmod 600 homelab-secrets.env
   ```
3. Generate all environment files, format OpenTofu HCL, and synchronize GitHub repository secrets:
   ```bash
   /root/homelab-iac/scripts/bootstrap-secrets.sh
   ```
   *Generates `tofu/terraform.tfvars`, `stacks/monitoring/.env`, formats HCL code with `tofu fmt`, syncs Discord webhook secrets to GitHub via `gh secret set`, and automatically invokes instance hooks if present.*

### Step 3: Provision All Containers Declaratively with OpenTofu
```bash
cd /root/homelab-iac/tofu

# Initialize OpenTofu provider
tofu init

# Review execution plan
tofu plan

# Deploy all LXC containers across Utility Node (node-1) and Compute Node (node-2)
tofu apply -auto-approve
```

### Step 4: Configure Storage & Restore or Install Workloads

1. **Configure Synology NAS Storage & VZDump Backups**:
   ```bash
   /root/homelab-iac/scripts/setup-proxmox-nas-backups.sh
   ```

2. **Mount Persistent NAS Shares on Hosts**:
   Ensure `/mnt/nas/data` and `/mnt/nas/photos` are mounted in `/etc/fstab`:
   ```bash
   # On Utility Node (node-1) & Compute Node (node-2):
   mkdir -p /mnt/nas/data /mnt/nas/photos
   echo "10.0.0.4:/volume2/data /mnt/nas/data nfs defaults,vers=4 0 0" >> /etc/fstab
   echo "10.0.0.4:/volume2/photos /mnt/nas/photos nfs defaults,vers=4 0 0" >> /etc/fstab
   mount -a
   ```

3. **Install & Start Application Workloads**:
   ```bash
   # Core DNS & DHCP (CT 501 & CT 502)
   /root/homelab-iac/scripts/install-adguard.sh
   /root/homelab-iac/scripts/configure-adguard-dhcp.sh

   # Ingress Tunnels (CT 510 & CT 511)
   pct exec 510 -- bash -c "$(cat /root/homelab-iac/scripts/install-cloudflared.sh)"
   pct exec 511 -- bash -c "$(cat /root/homelab-iac/scripts/install-cloudflared.sh)"

   # Core Monitoring (CT 601)
   pct exec 601 -- bash -c "$(cat /root/homelab-iac/scripts/bootstrap-docker-host.sh) && cd /opt/monitoring && docker compose up -d"

   # Management Workspace Antigravity 2.0 Remote Control Service (CT 900)
   /root/homelab-iac/scripts/install-antigravity-remote.sh install --name mgmt-devops --no-prompt

   # Execute Custom Post-Restore Hooks (if present in scripts/instance/)
   if [ -x /root/homelab-iac/scripts/instance/post-restore-hook.sh ]; then
       /root/homelab-iac/scripts/instance/post-restore-hook.sh
   fi
   ```

4. **Install Automated Maintenance Cron Jobs**:
   ```bash
   /root/homelab-iac/scripts/setup-maintenance-cron.sh
   ```

5. **Post-Rebuild Security & Compliance Verification**:
   Execute the comprehensive DevSecOps security audit suite to confirm zero configuration drift, proper privilege encapsulation, and clean secret handling before routing production traffic:
   ```bash
   /root/homelab-iac/scripts/scan-security.sh
   ```

---

## 💾 Granular Database & Stateful Storage Recovery Runbooks

### 1. Generic PostgreSQL Container Stack (Docker Compose)
- **Target Workload**: Any PostgreSQL-backed stack (e.g. Vaultwarden, Paperless-ngx, Nextcloud)
- **Database Service**: `<app>_postgres`

**Backup Database:**
```bash
pct exec <CTID> -- docker exec -t <app>_postgres pg_dump -U <user> -d <dbname> -F c -b -v -f /var/lib/postgresql/data/<app>_backup.dump
```

**Restore Database:**
```bash
# 1. Stop application server to prevent active transactions
pct exec <CTID> -- bash -c "cd /opt/<app> && docker compose stop <app>-server"

# 2. Drop existing database and recreate
pct exec <CTID> -- docker exec -t <app>_postgres psql -U <user> -d postgres -c "DROP DATABASE <dbname>;"
pct exec <CTID> -- docker exec -t <app>_postgres psql -U <user> -d postgres -c "CREATE DATABASE <dbname>;"

# 3. Restore from dump archive
pct exec <CTID> -- docker exec -t <app>_postgres pg_restore -U <user> -d <dbname> -v /var/lib/postgresql/data/<app>_backup.dump

# 4. Restart application stack
pct exec <CTID> -- bash -c "cd /opt/<app> && docker compose up -d"
```

---

### 2. Generic SQLite & Stateful Application Volumes
- **Target Workload**: SQLite-backed services (e.g. microservices, wikis, custom tools)

**Check Database Integrity:**
```bash
pct exec <CTID> -- sqlite3 /opt/<app>/config/<app>.sqlitedb "PRAGMA integrity_check;"
```

**Backup Database & Configuration:**
```bash
pct exec <CTID> -- bash -c "sqlite3 /opt/<app>/config/<app>.sqlitedb '.backup /tmp/<app>_backup.sqlitedb'"
pct exec <CTID> -- tar -czf /tmp/<app>_full_config.tar.gz -C /opt/<app>/config .
```

**Restore Database:**
```bash
# 1. Stop service / container
pct exec <CTID> -- bash -c "cd /opt/<app> && docker compose stop"

# 2. Restore SQLite database snapshot
pct exec <CTID> -- cp /tmp/<app>_backup.sqlitedb /opt/<app>/config/<app>.sqlitedb
pct exec <CTID> -- chown 1000:1000 /opt/<app>/config/<app>.sqlitedb

# 3. Start service / container
pct exec <CTID> -- bash -c "cd /opt/<app> && docker compose start"
```

---

### 3. Core Observability Stack: Uptime Kuma (CT 601 on `node-1`)
- **Container**: CT 601 (`monitoring` on Utility Node `node-1`)
- **Docker Compose Dir**: `/opt/monitoring`
- **Database File**: `/opt/monitoring/data/kuma.db`

**Check Database Integrity:**
```bash
pct exec 601 -- sqlite3 /opt/monitoring/data/kuma.db "PRAGMA integrity_check;"
```

**Backup Database & Data Volume:**
```bash
pct exec 601 -- bash -c "sqlite3 /opt/monitoring/data/kuma.db '.backup /tmp/kuma_backup.db'"
pct exec 601 -- tar -czf /tmp/monitoring_data_backup.tar.gz -C /opt/monitoring/data .
```

**Restore Database:**
```bash
# 1. Stop Uptime Kuma container
pct exec 601 -- bash -c "cd /opt/monitoring && docker compose stop uptime-kuma"

# 2. Restore SQLite database snapshot
pct exec 601 -- cp /tmp/kuma_backup.db /opt/monitoring/data/kuma.db

# 3. Start Uptime Kuma container
pct exec 601 -- bash -c "cd /opt/monitoring && docker compose start uptime-kuma"
```

---

## 🚨 Emergency DNS Bypass & Cluster Outage Recovery

If both hypervisors or both AdGuard Home instances (`10.0.0.201` and `10.0.0.202`) are offline, client devices on the LAN will lose domain name resolution.

### Method 1: Router DHCP DNS Override (Fastest LAN Fix)
1. Access router web administration interface (`http://10.0.0.1`).
2. Navigate to **DHCP / LAN Settings**.
3. Update Primary and Secondary DNS servers from `10.0.0.201` / `10.0.0.202` to:
   - Primary: `9.9.9.9` (Quad9) or `1.1.1.1` (Cloudflare)
   - Secondary: `149.112.112.112` or `1.0.0.1`
4. Save and renew DHCP leases on connected client devices.

### Method 2: Client-Side Immediate Temporary Fix (Linux / macOS)
```bash
# Linux / macOS manual resolv.conf override
echo "nameserver 9.9.9.9" | sudo tee /etc/resolv.conf
```

### Method 3: Direct Proxmox Hypervisor Web UI Access
Even if DNS resolution is completely down, all nodes and services remain accessible via direct IP:
- **Utility Node (`node-1`) UI**: `https://10.0.0.10:8006/`
- **Compute Node (`node-2`) UI**: `https://10.0.0.20:8006/`
- **Centralized NAS UI**: `http://10.0.0.4:5000/`
- **Primary Router UI**: `http://10.0.0.1/`
