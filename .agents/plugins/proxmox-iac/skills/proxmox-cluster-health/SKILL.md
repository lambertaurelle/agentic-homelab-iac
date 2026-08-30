---
name: proxmox-cluster-health
description: Inspect and audit Proxmox VE hypervisor cluster health, quorum status, storage pools, DNS resolution, and OpenTofu infrastructure drift. Use when the user asks to check cluster health, verify quorum, audit storage, run drift detection, or verify Proxmox cluster state.
---

# Proxmox Cluster Health & Drift Auditor

## Overview
This skill performs fast, read-only diagnostic audits of the Proxmox VE cluster health baseline: verifying Corosync quorum (`pvecm status`), hypervisor storage pool states (`pvesm status`), network DNS resolution, and declarative OpenTofu infrastructure drift (`tofu plan -detailed-exitcode`).

## When to Use
Use when:
- Checking cluster membership, quorum status, or node availability;
- Auditing local (`local-lvm`, `local-zfs`) or network storage pools (`nfs`, `pbs`);
- Verifying whether live hypervisor state matches declarative OpenTofu configurations;
- Testing DNS resolution and gateway reachability across nodes.

Do **not** use for:
- Initial Day-0 cluster setup (use `proxmox-bootstrap`);
- Debugging a specific failing application or container logs (use `proxmox-workload-debug`);
- Performing updates or reboots (use `proxmox-maintenance`);
- Provisioning new workloads (use `proxmox-scaffold-app`).

## Core Process

### 1. Cluster Membership & Quorum Audit
Verify node communication and cluster quorum:
```bash
# Check Corosync cluster status
pvecm status 2>/dev/null || echo "Running on standalone single node"

# Check active nodes
pvesh get /nodes --output-format json 2>/dev/null || true
```

### 2. Storage Pool Connectivity
Inspect health of all defined storage pools:
```bash
# Audit storage pool states
pvesm status
```
Verify that required storage pools report `active` status.

### 3. Core DNS & Gateway Health
Test DNS queries against primary and optional secondary resolvers:
```bash
# Check primary AdGuard DNS resolution
dig @127.0.0.1 google.com +time=2 +tries=1 2>/dev/null || true

# Test default gateway connectivity
ip route show default
```

### 4. Declarative OpenTofu Drift Detection
Run a non-destructive drift check against live state:
```bash
cd tofu
tofu plan -detailed-exitcode -compact-warnings || {
    EXIT_CODE=$?
    if [ "$EXIT_CODE" -eq 2 ]; then
        echo "[!] Drift detected between live infrastructure and OpenTofu state."
    elif [ "$EXIT_CODE" -eq 1 ]; then
        echo "[-] OpenTofu planning failed with an error."
    fi
}
```

## Verification
Confirm the health check is complete only when:
- [ ] Quorum state is verified (`Quorate: Yes` on multi-node or confirmed single-node).
- [ ] Storage pool statuses are reported with capacity utilization percentages.
- [ ] OpenTofu drift status is evaluated (0 changes vs drift detected).
- [ ] A structured health report is presented to the user with actionable next steps if issues are found.
