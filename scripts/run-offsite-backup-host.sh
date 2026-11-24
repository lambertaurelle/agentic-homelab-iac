#!/usr/bin/env bash
# ==============================================================================
# Offsite Cloud Backup Host Orchestrator (scope: core)
# ==============================================================================
# Invoked by /etc/cron.d/homelab-offsite-backup on node-1 (or manually).
# Responsibilities:
#   1. Acquire single-instance host lock (/var/run/homelab-offsite-host.lock)
#   2. Wait for active local VZDump jobs across cluster nodes to finish
#   3. Run optional scripts/instance/pre-offsite-backup-hook.sh (if present)
#   4. Start ephemeral backup worker container (CT 602) & wait for completion
#   5. Run optional scripts/instance/post-offsite-backup-hook.sh (always via trap)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

NODE2_IP="${NODE2_IP:-10.0.0.20}"
CTID="${OFFSITE_BACKUP_CT_ID:-602}"
MAX_WAIT_SEC="${OFFSITE_BACKUP_HOST_TIMEOUT_SEC:-14400}"

LOCK_FILE="/var/run/homelab-offsite-host.lock"
exec 201>"${LOCK_FILE}"
if ! flock -n 201; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [-] Offsite backup host runner already active. Exiting."
    exit 0
fi

PRE_HOOK="${SCRIPT_DIR}/instance/pre-offsite-backup-hook.sh"
POST_HOOK="${SCRIPT_DIR}/instance/post-offsite-backup-hook.sh"
PRE_HOOK_RAN=false

# shellcheck disable=SC2317,SC2329
cleanup_post_hook() {
    if [ "${PRE_HOOK_RAN}" = true ] && [ -x "${POST_HOOK}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [*] Invoking post-offsite-backup hook..."
        bash "${POST_HOOK}" || true
    fi
}
trap cleanup_post_hook EXIT INT TERM

# 1. Wait for any active VZDump job on node-1 or node-2
while pgrep -x vzdump >/dev/null 2>&1 || ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=2 "root@${NODE2_IP}" "pgrep -x vzdump >/dev/null 2>&1" 2>/dev/null; do
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [*] Waiting for active VZDump job to finish..."
    sleep 30
done

# 2. Pre-backup hook (e.g. non-disruptive in-game notices)
if [ -x "${PRE_HOOK}" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [*] Invoking pre-offsite-backup hook..."
    bash "${PRE_HOOK}" || true
    PRE_HOOK_RAN=true
fi

# 3. Start ephemeral offsite backup worker or service
echo "[$(date '+%Y-%m-%d %H:%M:%S')] [*] Triggering offsite backup worker (CT ${CTID})..."
if pct status "${CTID}" 2>/dev/null | grep -q "running"; then
    pct exec "${CTID}" -- systemctl start offsite-backup.service
elif pct status "${CTID}" >/dev/null 2>&1; then
    pct start "${CTID}"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [-] CT ${CTID} not found on this host." >&2
    exit 1
fi

# 4. Wait cleanly until ephemeral CT powers off (or timeout reached)
START_TS=$(date +%s)
sleep 10
while pct status "${CTID}" 2>/dev/null | grep -q "running"; do
    NOW_TS=$(date +%s)
    if [ $((NOW_TS - START_TS)) -ge "${MAX_WAIT_SEC}" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [!] Timeout waiting for CT ${CTID} to power off after ${MAX_WAIT_SEC}s." >&2
        break
    fi
    sleep 15
done

echo "[$(date '+%Y-%m-%d %H:%M:%S')] [+] Offsite backup worker (CT ${CTID}) finished."
exit 0
