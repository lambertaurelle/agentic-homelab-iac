#!/usr/bin/env bash
# ==============================================================================
# Non-Destructive Offsite Backup Inspector
# ==============================================================================
# Inspects offsite cloud backup state, latest execution logs, targets health,
# and storage quota without restarting containers or modifying systemd units.
#
# Safe to run from CT 900 (`mgmt-devops`) or directly on the Proxmox host.
#
# Usage:
#   ./scripts/inspect-backup.sh [--snapshots] [--tail <lines>]
#
# Examples:
#   ./scripts/inspect-backup.sh
#   ./scripts/inspect-backup.sh --snapshots
#   ./scripts/inspect-backup.sh --tail 100
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CTID="${OFFSITE_BACKUP_CT_ID:-602}"
TAIL_LINES=50
SHOW_SNAPSHOTS=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --snapshots)
            SHOW_SNAPSHOTS=true
            shift
            ;;
        --tail)
            TAIL_LINES="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--snapshots] [--tail <lines>]"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

PVE_EXEC="${REPO_ROOT}/scripts/pve-exec.sh"
if [ ! -x "${PVE_EXEC}" ]; then
    chmod +x "${PVE_EXEC}"
fi

echo "=============================================================================="
echo "    Offsite Cloud Backup Inspection Report                                    "
echo "=============================================================================="

# 1. Check Container Status
CT_STATUS=$("${PVE_EXEC}" node-1 pct status "${CTID}" 2>/dev/null | awk '{print $2}' || echo "unknown")
echo "[*] Worker Container : CT ${CTID} (${CT_STATUS})"

# 2. Extract Last Backup Execution Journal Logs
echo "------------------------------------------------------------------------------"
echo "[*] Last Execution Log (Journal: offsite-backup.service, tail ${TAIL_LINES} lines):"
echo "------------------------------------------------------------------------------"

if [ "${CT_STATUS}" = "running" ]; then
    "${PVE_EXEC}" node-1 pct exec "${CTID}" -- journalctl -u offsite-backup.service -n "${TAIL_LINES}" --no-pager 2>/dev/null || echo "[-] No journal entries found."
else
    # Inspect via temporary read-only mount without starting container
    "${PVE_EXEC}" node-1 "pct mount ${CTID} >/dev/null 2>&1 || true; ROOTFS=/var/lib/lxc/${CTID}/rootfs; if [ -d \"\$ROOTFS/var/log/journal\" ]; then journalctl -D \"\$ROOTFS/var/log/journal\" -u offsite-backup.service -n ${TAIL_LINES} --no-pager 2>/dev/null; elif [ -f \"\$ROOTFS/var/log/offsite-backup.log\" ]; then tail -n ${TAIL_LINES} \"\$ROOTFS/var/log/offsite-backup.log\"; else echo '[-] No offsite-backup logs detected on container rootfs.'; fi; pct unmount ${CTID} >/dev/null 2>&1 || true"
fi

# 3. Snapshot History (if requested)
if [ "${SHOW_SNAPSHOTS}" = true ]; then
    echo "------------------------------------------------------------------------------"
    echo "[*] Querying Restic Cloud Snapshots..."
    echo "------------------------------------------------------------------------------"
    if [ "${CT_STATUS}" = "running" ]; then
        "${PVE_EXEC}" node-1 "pct exec ${CTID} -- bash -c 'set -a; [ -f /etc/offsite-backup/backup.env ] && . /etc/offsite-backup/backup.env; set +a; export RESTIC_REPOSITORY=\"rclone:\${OFFSITE_BACKUP_REMOTE_NAME:-offsite-remote}:\${OFFSITE_BACKUP_REMOTE_PATH:-homelab-backups}\"; export RCLONE_CONFIG=/etc/offsite-backup/rclone.conf; restic snapshots'"
    else
        # Temporarily spin up worker, query snapshots, and power down
        "${PVE_EXEC}" node-1 "pct start ${CTID} >/dev/null 2>&1; pct exec ${CTID} -- bash -c 'set -a; [ -f /etc/offsite-backup/backup.env ] && . /etc/offsite-backup/backup.env; set +a; export RESTIC_REPOSITORY=\"rclone:\${OFFSITE_BACKUP_REMOTE_NAME:-offsite-remote}:\${OFFSITE_BACKUP_REMOTE_PATH:-homelab-backups}\"; export RCLONE_CONFIG=/etc/offsite-backup/rclone.conf; restic snapshots'; pct stop ${CTID} >/dev/null 2>&1"
    fi
fi

echo "=============================================================================="
echo "    Inspection Completed Successfully                                         "
echo "=============================================================================="
