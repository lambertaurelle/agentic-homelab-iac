#!/usr/bin/env bash
# ==============================================================================
# Proxmox NAS NFS Backup Pool & Automated VZDump Schedule Setup
# ==============================================================================
# Phase 2: Disaster Recovery & Backup Automation
#
# Configures:
#   1. NFS Storage pool 'syno-backup' targeting NFS backup share
#   2. Backup retention policy: keep-daily=3, keep-weekly=2
#   3. Dump directory permissions (/mnt/pve/syno-backup/dump)
#   4. Multi-node storage activation across 'node-1' and 'node-2'
#   5. Automated daily snapshot backups for all LXC containers cluster-wide (--all 1):
#      Automatically includes all current and future guest containers/workloads
#      Scheduled at 03:00 AM daily with zstd compression & failure alerts
# ==============================================================================
set -euo pipefail

# Dynamic configuration sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

NODE1_IP="${NODE1_IP:-10.0.0.10}"
NODE2_IP="${NODE2_IP:-10.0.0.20}"
NFS_SERVER="${NFS_SERVER:-${NAS_IP:-10.0.0.4}}"
NFS_EXPORT="${NFS_EXPORT:-/mnt/nas/data}"
STORAGE_ID="syno-backup"
STORAGE_PATH="/mnt/pve/syno-backup"
PRUNE_RETENTION="keep-daily=3,keep-weekly=2"
BACKUP_ALL="1"
# shellcheck disable=SC2034
BACKUP_SCHEDULE_TIME="03:00"
BACKUP_MODE="snapshot"
BACKUP_COMPRESS="zstd"
BACKUP_MAILNOTIFY="failure"

echo "=============================================================================="
echo "    Proxmox VE Cluster NAS Backup & VZDump Automation Setup                  "
echo "=============================================================================="

# Helper function to execute commands on master node (node-1)
run_on_master() {
    local cmd="$1"
    if ip addr show 2>/dev/null | grep -q "${NODE1_IP}" || [[ "${NODE1_IP}" == "localhost" ]] || [[ "${NODE1_IP}" == "127.0.0.1" ]]; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no "root@${NODE1_IP}" "${cmd}"
    fi
}

# Helper function to execute commands on secondary node (node-2)
run_on_secondary() {
    local cmd="$1"
    if ip addr show 2>/dev/null | grep -q "${NODE2_IP}"; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no "root@${NODE2_IP}" "${cmd}"
    fi
}

# ------------------------------------------------------------------------------
# 1. Check Node Connectivity
# ------------------------------------------------------------------------------
echo "[*] Step 1/4: Checking cluster node connectivity..."
if ! run_on_master "pvecm status" >/dev/null 2>&1; then
    echo "[-] Error: Unable to reach Proxmox master node at ${NODE1_IP}" >&2
    exit 1
fi
echo "[+] Proxmox master node (${NODE1_IP}) is reachable."

if ! run_on_secondary "hostname" >/dev/null 2>&1; then
    echo "[-] Error: Unable to reach Proxmox worker node at ${NODE2_IP}" >&2
    exit 1
fi
echo "[+] Proxmox worker node (${NODE2_IP}) is reachable."

# ------------------------------------------------------------------------------
# 2. Configure NFS Storage Pool 'syno-backup'
# ------------------------------------------------------------------------------
echo "[*] Step 2/4: Configuring NFS Storage Pool '${STORAGE_ID}' on Proxmox cluster..."

STORAGE_EXISTS=$(run_on_master "pvesm status -storage ${STORAGE_ID} >/dev/null 2>&1 && echo 'yes' || echo 'no'")

if [ "${STORAGE_EXISTS}" = "no" ]; then
    echo "[*] Adding NFS storage pool '${STORAGE_ID}'..."
    run_on_master "pvesm add nfs ${STORAGE_ID} \
        --server ${NFS_SERVER} \
        --export ${NFS_EXPORT} \
        --path ${STORAGE_PATH} \
        --content backup \
        --prune-backups ${PRUNE_RETENTION}"
    echo "[+] Storage '${STORAGE_ID}' added successfully."
else
    echo "[*] Storage '${STORAGE_ID}' already exists. Ensuring configuration and retention parameters..."
    run_on_master "pvesm set ${STORAGE_ID} \
        --content backup \
        --prune-backups ${PRUNE_RETENTION} \
        --disable 0"
    echo "[+] Storage '${STORAGE_ID}' configuration updated."
fi

# Ensure dump directory and permissions on Synology share
echo "[*] Verifying dump directory '${STORAGE_PATH}/dump' and permissions on Synology..."
run_on_master "mkdir -p ${STORAGE_PATH}/dump && chmod 777 ${STORAGE_PATH}/dump"
echo "[+] Directory '${STORAGE_PATH}/dump' is ready with read/write permissions."

# ------------------------------------------------------------------------------
# 3. Activate Storage on All Cluster Nodes
# ------------------------------------------------------------------------------
echo "[*] Step 3/4: Activating and verifying '${STORAGE_ID}' on both cluster nodes..."

# Refresh/check node-1
NODE1_STATUS=$(run_on_master "pvesm status -storage ${STORAGE_ID}" | awk 'NR>1 {print $3}')
if [ "${NODE1_STATUS}" != "active" ]; then
    echo "[*] Reactivating storage on node-1..."
    run_on_master "pvesm set ${STORAGE_ID} --disable 0; pvesm status -storage ${STORAGE_ID}"
    NODE1_STATUS=$(run_on_master "pvesm status -storage ${STORAGE_ID}" | awk 'NR>1 {print $3}')
fi

# Refresh/check node-2
NODE2_STATUS=$(run_on_secondary "pvesm status -storage ${STORAGE_ID}" | awk 'NR>1 {print $3}')
if [ "${NODE2_STATUS}" != "active" ]; then
    echo "[*] Activating storage mount on node-2..."
    run_on_secondary "pvesm set ${STORAGE_ID} --disable 0 >/dev/null 2>&1 || true; pvesm status -storage ${STORAGE_ID} >/dev/null 2>&1 || true"
    sleep 2
    NODE2_STATUS=$(run_on_secondary "pvesm status -storage ${STORAGE_ID}" | awk 'NR>1 {print $3}')
fi

echo "[+] Node 1 ('node-1') storage status: ${NODE1_STATUS}"
echo "[+] Node 2 ('node-2') storage status: ${NODE2_STATUS}"

if [ "${NODE1_STATUS}" != "active" ] || [ "${NODE2_STATUS}" != "active" ]; then
    echo "[-] Error: Storage '${STORAGE_ID}' is not active on all nodes." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 4. Configure Automated VZDump Backup Schedule
# ------------------------------------------------------------------------------
echo "[*] Step 4/4: Configuring automated daily VZDump cron schedule in /etc/pve/vzdump.cron..."

# Format /etc/pve/vzdump.cron using cluster-wide --all 1
run_on_master "cat << 'CRONEOF' > /etc/pve/vzdump.cron
# cluster wide vzdump cron schedule
# Automatically generated file - do not edit

PATH=\"/usr/sbin:/usr/bin:/sbin:/bin\"

0 3 * * *           root vzdump --all ${BACKUP_ALL} --compress ${BACKUP_COMPRESS} --mailnotification ${BACKUP_MAILNOTIFY} --mode ${BACKUP_MODE} --storage ${STORAGE_ID}
CRONEOF"

echo "[+] vzdump.cron updated successfully on cluster filesystem (/etc/pve)."

# ------------------------------------------------------------------------------
# Verification Summary
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "    Verification & Status Summary                                             "
echo "=============================================================================="

echo "[*] Proxmox Storage Status (node-1):"
run_on_master "pvesm status -storage ${STORAGE_ID}"

echo "[*] Proxmox Storage Status (node-2):"
run_on_secondary "pvesm status -storage ${STORAGE_ID}"

echo "[*] /etc/pve/storage.cfg configuration for '${STORAGE_ID}':"
run_on_master "sed -n '/nfs: ${STORAGE_ID}/,/^$/p' /etc/pve/storage.cfg"

echo "[*] /etc/pve/vzdump.cron content:"
run_on_master "cat /etc/pve/vzdump.cron"

echo "[*] Cluster Backup Jobs (pvesh get /cluster/backup):"
run_on_master "pvesh get /cluster/backup"

echo "=============================================================================="
echo "    NAS Backup Storage & VZDump Automation Configured Successfully!           "
echo "=============================================================================="
