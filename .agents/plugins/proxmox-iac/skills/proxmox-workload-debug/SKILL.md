---
name: proxmox-workload-debug
description: Diagnose, troubleshoot, and inspect Proxmox LXC containers, Docker Compose stacks, systemd services, and container network routing. Use when the user asks to debug a container, inspect container logs, fix a service restart loop, troubleshoot a failing stack, or investigate network reachability.
---

# Proxmox Workload Debugger & Troubleshooting Expert

## Overview
This skill guides the sysadmin through diagnosing and resolving failures in Proxmox LXC containers and nested Docker Compose workloads. It executes safe diagnostic inspections: container lifecycle states (`pct status`), systemd journal logs (`journalctl`), Docker daemon and compose logs (`docker logs`), port conflicts (`ss -tulpn`), and network bridge routing.

## When to Use
Use when:
- An LXC container fails to start, crashes, or hangs in an error state;
- A Docker Compose stack inside an LXC is restarting in a loop or exiting with non-zero codes;
- Diagnosing application logs, permission denied errors, or out-of-memory (OOM) kills;
- Investigating network connectivity, DNS failures, or port binding collisions inside guest workloads.

Do **not** use for:
- Hypervisor-wide quorum or cluster storage pool audits (use `proxmox-cluster-health`);
- Performing routine software updates or scheduled reboots (use `proxmox-maintenance`);
- Onboarding or provisioning new containers (use `proxmox-scaffold-app`).

## Execution Environment & Topology Awareness
> [!IMPORTANT]
> The agent executes inside the **Management Workspace (`mgmt-devops`, CT 900)**. Proxmox hypervisor commands (`pct`, `pvesm`, etc.) are not present locally.
> Always route hypervisor commands through [`scripts/pve-exec.sh`](file:///root/homelab-iac/scripts/pve-exec.sh) targeting the appropriate node (`node-1` for utility workloads, `node-2` for compute/application workloads).

---

## Core Process

### 1. Identify Target Workload & Host Node
Identify the target Container ID (CTID) or application name from the user request or by querying running containers across nodes:
```bash
# List containers on node-1 (Utility Node) and node-2 (Compute Node)
./scripts/pve-exec.sh node-1 pct list 2>/dev/null || true
./scripts/pve-exec.sh node-2 pct list 2>/dev/null || true
```

### 2. Inspect LXC Container Status & Resources
Check container lifecycle status, CPU/RAM utilization, and configuration:
```bash
# Check status and configuration of target container on target node (e.g. NODE=node-1, CTID=601)
./scripts/pve-exec.sh "$NODE" pct status "$CTID"
./scripts/pve-exec.sh "$NODE" pct config "$CTID"
```

### 3. Inspect Systemd Journal & Docker Logs
Extract recent failure logs from inside the container:
```bash
# Check systemd journal for container boot or service errors
./scripts/pve-exec.sh "$NODE" "pct exec $CTID -- journalctl -xe --no-pager -n 50" 2>/dev/null || true

# If container runs Docker, check Docker daemon and Compose logs
./scripts/pve-exec.sh "$NODE" "pct exec $CTID -- docker ps -a" 2>/dev/null || true
./scripts/pve-exec.sh "$NODE" "pct exec $CTID -- docker logs --tail 50 <container_name>" 2>/dev/null || true
```

### 4. Diagnose Port Conflicts & Network Reachability
Check listening ports and container networking:
```bash
# Check listening ports inside container
./scripts/pve-exec.sh "$NODE" "pct exec $CTID -- ss -tulpn" 2>/dev/null || true

# Test DNS and gateway connectivity from inside container
./scripts/pve-exec.sh "$NODE" "pct exec $CTID -- ping -c 2 1.1.1.1" 2>/dev/null || true
./scripts/pve-exec.sh "$NODE" "pct exec $CTID -- nslookup google.com" 2>/dev/null || true
```

### 5. Propose & Apply Remediation
Based on the root cause identified (OOM, missing volume, permission mapping, port collision):
- Adjust memory/cores in `tofu/` or via `pct set "$CTID" -memory <MB>`.
- Fix Docker Compose environment variables in `stacks/instance/<app>/.env` (or `stacks/<app>/.env`).
- Restart service: `pct exec "$CTID" -- systemctl restart <service>` or `pct reboot "$CTID"`.

## Verification
Confirm the troubleshooting session is complete only when:
- [ ] Root cause of the failure is clearly identified and explained to the user.
- [ ] Target container and its constituent services report status `running` / `healthy`.
- [ ] Application responds to local health check or HTTP probe without error.
