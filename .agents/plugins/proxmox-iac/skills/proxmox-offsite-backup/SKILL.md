---
name: proxmox-offsite-backup
description: Manage, configure, and orchestrate automated differential offsite backups to cloud storage (pCloud, S3, B2) via Restic + Rclone. Use when the user asks to add or remove folders from offsite backup, check cloud backup status, trigger an offsite backup, audit remote quota, or restore data from cloud snapshots.
---

# Proxmox Offsite Cloud Backup Expert

## Overview
This skill manages the secondary offsite tier of the homelab disaster recovery architecture. It orchestrates encrypted, differential, chunk-deduplicated replication from local Proxmox storage and NAS volumes to cloud storage providers (such as pCloud, Backblaze B2, or AWS S3). It manages declarative backup targets in `config/instance/backup-targets.yaml` and executes backups through the dedicated ephemeral worker container `CT 602` (`offsite-backup`).

## When to Use
Use when:
- Adding a new folder, dataset, or container dump to the offsite backup targets list;
- Removing or disabling an existing directory from offsite backups;
- Checking the status, snapshot history, or storage quota usage of cloud backups;
- Triggering an on-demand differential offsite backup run;
- Restoring files, directories, or snapshot archives from cloud storage.

Do **not** use for:
- Local hypervisor VZDump configuration (use `proxmox-maintenance`);
- Routine cluster OS upgrades or host reboots (use `proxmox-maintenance`);
- Scaffolding new application workloads (use `proxmox-scaffold-app`).

---

## Standard Execution Procedure

Follow these sequential steps when managing offsite cloud backups:

### Step 1: Inspect Status & Cloud Storage Quota
Before making configuration changes or triggering a backup, audit the remote storage quota:
```bash
pct exec 602 -- rclone about offsite-remote:
```
Confirm that storage usage is below the warning threshold (`85%`).

### Step 2: Manage or Verify Backup Targets
1. View all configured backup sources and their enablement status:
   ```bash
   ./scripts/manage-backup-targets.sh list
   ```
2. To add a new folder or dataset:
   ```bash
   ./scripts/manage-backup-targets.sh add --name "my-dataset" --path "/mnt/backup-source/nas-data/my-dataset" --desc "Description" --exclude "*.tmp,*.part"
   ```
3. To enable or disable an existing target:
   ```bash
   ./scripts/manage-backup-targets.sh enable --name "siyuan-notes"
   ./scripts/manage-backup-targets.sh disable --name "frigate-cctv"
   ```
4. Verify target directory accessibility inside CT 602:
   ```bash
   pct exec 602 -- manage-backup-targets verify
   ```

### Step 3: Trigger Differential Backup Execution
Execute the differential cloud backup via the single idempotent command:
```bash
# Start ephemeral worker or trigger service if already started:
if pct status 602 2>/dev/null | grep -q 'running'; then
    pct exec 602 -- systemctl start offsite-backup.service
else
    pct start 602
fi
```
The runner will stream modified chunks in RAM to cloud storage, prune retention (`keep-daily 3, keep-weekly 2`), audit quota, send a Discord report embed, and automatically power off the container upon completion.

### Step 4: Verify Completion & Notification
1. Monitor until container auto-powers off (or check journal logs if still active):
   ```bash
   # Wait for clean ephemeral shutdown
   while pct status 602 2>/dev/null | grep -q 'running'; do sleep 5; done
   ```
2. View recorded point-in-time snapshots (starts worker temporarily if powered off):
   ```bash
   pct start 602 && pct exec 602 -- restic snapshots && pct stop 602
   ```

### Step 5: Disaster Recovery & Restoration (When Needed)
To recover data from cloud storage:
1. Identify the desired snapshot ID using `pct exec 602 -- restic snapshots`.
2. Restore the target archive or directory:
   ```bash
   pct exec 602 -- restic restore <SNAPSHOT_ID> --target /mnt/backup-source/nas-data/restored/
   ```

---

## Verification & Safety Checklist
Before confirming completion of an offsite backup operation:
- [ ] Ensure `config/instance/backup-targets.yaml` is valid YAML.
- [ ] Verify that new targets do not include disposable multi-terabyte media that would exhaust cloud quota.
- [ ] Confirm `rclone about` usage remains safely below the 85% warning threshold.
- [ ] Verify Discord webhook notification reflects successful completion.
