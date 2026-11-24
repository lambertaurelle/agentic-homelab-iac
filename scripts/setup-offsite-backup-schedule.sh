#!/usr/bin/env bash
# ==============================================================================
# Offsite Backup Host Scheduler Setup (03:45 AM Daily)
# ==============================================================================
# Installs an automated daily trigger on Proxmox node-1 (Utility Node) to start
# ephemeral backup container CT 602 at 03:45 AM (post-VZDump 03:00 AM backup).
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

NODE1_IP="${NODE1_IP:-10.0.0.10}"
NODE2_IP="${NODE2_IP:-10.0.0.20}"
CTID="${OFFSITE_BACKUP_CT_ID:-602}"
SCHEDULE_TIME="${OFFSITE_BACKUP_SCHEDULE:-45 3 * * *}"

# Helper to run on node-1
run_on_master() {
    local cmd="$1"
    if ip addr show 2>/dev/null | grep -q "${NODE1_IP}" || [[ "${NODE1_IP}" == "localhost" ]] || [[ "${NODE1_IP}" == "127.0.0.1" ]]; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no "root@${NODE1_IP}" "${cmd}"
    fi
}

echo "=============================================================================="
echo "    Proxmox Host Offsite Cloud Backup Scheduler Setup                        "
echo "=============================================================================="
echo "[*] Target Host       : ${NODE1_IP}"
echo "[*] Container ID      : ${CTID}"
echo "[*] Cron Schedule     : ${SCHEDULE_TIME} (Daily 03:45 AM)"

# 1. Verify container existence
echo "[*] Checking if CT ${CTID} exists on cluster..."
if ! run_on_master "pct status ${CTID} >/dev/null 2>&1"; then
    echo "[!] Notice: Container CT ${CTID} does not exist yet on the cluster."
    echo "    Schedule configuration will be prepared and active once OpenTofu applies CT ${CTID}."
else
    echo "[+] Container CT ${CTID} detected."
fi

# 2. Sync host orchestrator script & configure Host Crontab on node-1
HOST_RUNNER="/root/homelab-iac/scripts/run-offsite-backup-host.sh"
if [ -f "${SCRIPT_DIR}/run-offsite-backup-host.sh" ]; then
    run_on_master "mkdir -p /root/homelab-iac/scripts/instance"
    if ip addr show 2>/dev/null | grep -q "${NODE1_IP}" || [[ "${NODE1_IP}" == "localhost" ]] || [[ "${NODE1_IP}" == "127.0.0.1" ]]; then
        install -m 755 "${SCRIPT_DIR}/run-offsite-backup-host.sh" "${HOST_RUNNER}"
    else
        scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}/run-offsite-backup-host.sh" "root@${NODE1_IP}:${HOST_RUNNER}"
        run_on_master "chmod 755 ${HOST_RUNNER}"
    fi
fi

echo "[*] Installing cron trigger in /etc/cron.d/homelab-offsite-backup on ${NODE1_IP}..."
run_on_master "cat << 'CRONEOF' > /etc/cron.d/homelab-offsite-backup
# /etc/cron.d/homelab-offsite-backup
# Automatically starts ephemeral offsite backup container post-VZDump (03:45 AM)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

${SCHEDULE_TIME} root ${HOST_RUNNER} >> /var/log/homelab-offsite-backup.log 2>&1
CRONEOF
chmod 644 /etc/cron.d/homelab-offsite-backup"

echo "[+] Cron schedule installed successfully."
echo "[*] Active schedule:"
run_on_master "cat /etc/cron.d/homelab-offsite-backup"

echo "=============================================================================="
echo "    Offsite Backup Schedule Configured Successfully!                          "
echo "=============================================================================="
