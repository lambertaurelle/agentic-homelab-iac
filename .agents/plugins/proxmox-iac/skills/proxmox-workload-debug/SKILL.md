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

## Core Process

### 1. Identify Target Workload & Host Node
Identify the target Container ID (CTID) or application name from the user request or by querying running containers:
```bash
# List containers across the local node
pct list 2>/dev/null || true
```

### 2. Inspect LXC Container Status & Resources
Check container lifecycle status, CPU/RAM utilization, and configuration:
```bash
# Check status and configuration of target container (e.g. CTID=601)
pct status "$CTID"
pct config "$CTID"
```

### 3. Inspect Systemd Journal & Docker Logs
Extract recent failure logs from inside the container:
```bash
# Check systemd journal for container boot or service errors
pct exec "$CTID" -- journalctl -xe --no-pager -n 50 2>/dev/null || true

# If container runs Docker, check Docker daemon and Compose logs
pct exec "$CTID" -- docker ps -a 2>/dev/null || true
pct exec "$CTID" -- docker logs --tail 50 "<container_name>" 2>/dev/null || true
```

### 4. Diagnose Port Conflicts & Network Reachability
Check listening ports and container networking:
```bash
# Check listening ports inside container
pct exec "$CTID" -- ss -tulpn 2>/dev/null || true

# Test DNS and gateway connectivity from inside container
pct exec "$CTID" -- ping -c 2 1.1.1.1 2>/dev/null || true
pct exec "$CTID" -- nslookup google.com 2>/dev/null || true
```

### 5. Propose & Apply Remediation
Based on the root cause identified (OOM, missing volume, permission mapping, port collision):
- Adjust memory/cores in `tofu/` or via `pct set "$CTID" -memory <MB>`.
- Fix Docker Compose environment variables in `stacks/<app>/.env`.
- Restart service: `pct exec "$CTID" -- systemctl restart <service>` or `pct reboot "$CTID"`.

## Verification
Confirm the troubleshooting session is complete only when:
- [ ] Root cause of the failure is clearly identified and explained to the user.
- [ ] Target container and its constituent services report status `running` / `healthy`.
- [ ] Application responds to local health check or HTTP probe without error.
