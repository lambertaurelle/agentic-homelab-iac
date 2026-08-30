---
name: proxmox-maintenance
description: Orchestrate Proxmox VE hypervisor and container maintenance, automated daily updates, rolling node reboots with safety guards, and snapshot backup/restore operations. Use when the user asks to run cluster maintenance, update containers, perform a rolling reboot, backup guests, or restore snapshots.
---

# Proxmox Maintenance & Disaster Recovery Expert

## Overview
This skill executes Day-2 maintenance, automated software updates, rolling node reboots, and snapshot disaster recovery operations across the Proxmox homelab cluster. It leverages battle-tested, idempotent shell scripts with built-in safety guards (peer node ping checks, quorum verification, and pre-flight health validations).

## When to Use
Use when:
- Executing routine software updates across hypervisor hosts, LXC containers, and Docker stacks (`update-cluster-stack.sh`);
- Performing scheduled rolling reboots with peer node reachability guards (`scheduled-reboot.sh`);
- Triggering manual or scheduled VZDump snapshot backups across all guest workloads (`setup-proxmox-nas-backups.sh`);
- Restoring containers or stacks from backup snapshots (`restore-all-lxc.sh`).

Do **not** use for:
- Initial Day-0 cluster bootstrapping (use `proxmox-bootstrap`);
- Read-only health and drift audits (use `proxmox-cluster-health`);
- Troubleshooting a specific broken container or inspecting logs (use `proxmox-workload-debug`);
- Scaffolding new application workloads (use `proxmox-scaffold-app`).

## Core Process

### 1. Daily Cluster & Container Updates
Run the non-interactive cluster update engine:
```bash
# Execute hypervisor apt updates, LXC container updates, and Docker Compose pulls
./scripts/update-cluster-stack.sh
```
This updates host packages, iterates through active LXC containers to run `apt-get upgrade`, and pulls updated images for Docker Compose stacks.

### 2. Rolling Node Reboot Orchestration
Perform a safe rolling reboot with pre-flight safety checks:
```bash
# Execute safe reboot engine on target node
./scripts/scheduled-reboot.sh
```
The script validates peer node reachability and DNS resolution before triggering the reboot. In single-node environments (`enable_ha = false`), peer checks are gracefully bypassed.

### 3. Snapshot Backup & Disaster Recovery
Trigger backup operations or restore workloads:
```bash
# 1. Trigger or configure daily VZDump snapshot backups
./scripts/setup-proxmox-nas-backups.sh

# 2. Interactive or bulk container restore from VZDump snapshots
./scripts/restore-all-lxc.sh --help
```

## Verification
Confirm the maintenance operation is complete only when:
- [ ] Update engine reports 0 unhandled package or container pull failures.
- [ ] Nodes are online and responsive after reboot with all guest containers in `running` state.
- [ ] VZDump backup snapshots are verified in the target storage pool.
- [ ] A clear execution summary is presented to the user.
