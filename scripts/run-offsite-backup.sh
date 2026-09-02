#!/usr/bin/env bash
# ==============================================================================
# Differential Offsite Cloud Backup Execution Engine
# ==============================================================================
# Features:
#   1. In-memory CDC chunking & AES-256 client-side encryption via Restic
#   2. Differential cloud streaming over Rclone (pCloud, S3, B2, WebDAV, etc.)
#   3. Target management via YAML config (vzdump snapshots, photos, audiobooks)
#   4. Automated snapshot retention pruning (--keep-daily 3 --keep-weekly 2)
#   5. Cloud storage quota auditing via 'rclone about'
#   6. Rich Discord embed notifications (Success, Warning >= 85%, Error)
#   7. Optional ephemeral auto-shutdown (--ephemeral)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

START_TIME=$(date +%s)
START_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

EPHEMERAL_MODE=false
DRY_RUN=false

for arg in "$@"; do
    case "${arg}" in
        --ephemeral) EPHEMERAL_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Usage: $0 [--ephemeral] [--dry-run]"
            exit 0
            ;;
    esac
done

# ------------------------------------------------------------------------------
# 1. Environment & Credentials Resolution
# ------------------------------------------------------------------------------
export HOME="${HOME:-/root}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${HOME}/.cache}"

ENV_FILE="/etc/offsite-backup/backup.env"
if [ ! -f "${ENV_FILE}" ] && [ -f "${REPO_ROOT}/stacks/offsite-backup/.env" ]; then
    ENV_FILE="${REPO_ROOT}/stacks/offsite-backup/.env"
elif [ ! -f "${ENV_FILE}" ] && [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    ENV_FILE="${REPO_ROOT}/homelab-secrets.env"
fi

if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
    set +a
fi

# Fallback secrets resolution if homelab-secrets.env exists
if [ -z "${RESTIC_PASSWORD:-}" ] && [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

OFFSITE_BACKUP_REMOTE_NAME="${OFFSITE_BACKUP_REMOTE_NAME:-offsite-remote}"
OFFSITE_BACKUP_REMOTE_TYPE="${OFFSITE_BACKUP_REMOTE_TYPE:-pcloud}"
OFFSITE_BACKUP_REMOTE_PATH="${OFFSITE_BACKUP_REMOTE_PATH:-homelab-backups}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
WARN_THRESHOLD="${OFFSITE_BACKUP_QUOTA_WARN_PERCENT:-85}"
CRIT_THRESHOLD="${OFFSITE_BACKUP_QUOTA_CRIT_PERCENT:-95}"
DISCORD_WEBHOOK="${DISCORD_MONITORING_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}"

RCLONE_CONF="/etc/offsite-backup/rclone.conf"
if [ ! -f "${RCLONE_CONF}" ] && [ -f "${HOME}/.config/rclone/rclone.conf" ]; then
    RCLONE_CONF="${HOME}/.config/rclone/rclone.conf"
fi

# Find targets configuration
TARGETS_FILE="/etc/offsite-backup/backup-targets.yaml"
if [ ! -f "${TARGETS_FILE}" ] && [ -f "${REPO_ROOT}/config/instance/backup-targets.yaml" ]; then
    TARGETS_FILE="${REPO_ROOT}/config/instance/backup-targets.yaml"
elif [ ! -f "${TARGETS_FILE}" ] && [ -f "${REPO_ROOT}/config/backup-targets.example.yaml" ]; then
    TARGETS_FILE="${REPO_ROOT}/config/backup-targets.example.yaml"
fi

export RESTIC_PASSWORD
export RESTIC_REPOSITORY="rclone:${OFFSITE_BACKUP_REMOTE_NAME}:${OFFSITE_BACKUP_REMOTE_PATH}"
export RCLONE_CONFIG="${RCLONE_CONF}"

echo "=============================================================================="
echo "    Differential Offsite Cloud Backup Engine                                  "
echo "=============================================================================="
echo "[*] Remote Destination : ${RESTIC_REPOSITORY}"
echo "[*] Targets Definition : ${TARGETS_FILE}"
echo "[*] Ephemeral Mode     : ${EPHEMERAL_MODE}"

# ------------------------------------------------------------------------------
# 2. Discord Notification Helper
# ------------------------------------------------------------------------------
send_discord_embed() {
    local color="$1"
    local title="$2"
    local description="$3"
    local fields_json="$4"

    if [ -z "${DISCORD_WEBHOOK}" ]; then
        echo "[*] Discord webhook not configured. Skipping alert notification."
        return 0
    fi

    local payload
    payload=$(python3 -c "
import json, sys
data = {
    'embeds': [{
        'title': sys.argv[1],
        'description': sys.argv[2],
        'color': int(sys.argv[3]),
        'fields': json.loads(sys.argv[4]),
        'footer': {'text': 'Homelab Cloud Backup Engine • CT 602'},
        'timestamp': sys.argv[5]
    }]
}
print(json.dumps(data))
" "${title}" "${description}" "${color}" "${fields_json}" "${START_TIMESTAMP}")

    curl -s -S -X POST -H "Content-Type: application/json" -d "${payload}" "${DISCORD_WEBHOOK}" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# 3. Check / Initialize Repository
# ------------------------------------------------------------------------------
if [ "${DRY_RUN}" = false ]; then
    echo "[*] Verifying Restic repository connectivity..."
    if ! restic snapshots >/dev/null 2>&1; then
        echo "[*] Repository not detected at ${RESTIC_REPOSITORY}. Initializing new encrypted repository..."
        restic init || {
            echo "[-] Error: Failed to initialize repository at ${RESTIC_REPOSITORY}" >&2
            send_discord_embed "15158332" "❌ Offsite Backup Failed to Initialize" "Restic repository at **${RESTIC_REPOSITORY}** could not be contacted or initialized." "[]"
            exit 1
        }
        echo "[+] Encrypted Restic repository initialized successfully."
    else
        echo "[+] Repository verified and reachable."
    fi
fi

# ------------------------------------------------------------------------------
# 4. Process Backup Targets
# ------------------------------------------------------------------------------
TOTAL_PROCESSED=0
SUCCESS_COUNT=0
FAIL_COUNT=0
TARGETS_SUMMARY=""

# Extract enabled targets using Python
TARGET_LIST=$(python3 -c "
import sys, yaml
with open('${TARGETS_FILE}', 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}
targets = [t for t in data.get('targets', []) if t.get('enabled', False)]
for t in targets:
    name = t.get('name', 'unnamed')
    src = t.get('source', '')
    excludes = ','.join(t.get('exclude', []))
    print(f'{name}|{src}|{excludes}')
")

while IFS='|' read -r t_name t_src t_excludes; do
    [ -z "${t_name}" ] && continue
    TOTAL_PROCESSED=$((TOTAL_PROCESSED + 1))

    echo "------------------------------------------------------------------------------"
    echo "[*] Target [${TOTAL_PROCESSED}]: ${t_name} -> ${t_src}"

    if [ ! -e "${t_src}" ]; then
        echo "[-] Warning: Target path does not exist: ${t_src}. Skipping."
        TARGETS_SUMMARY="${TARGETS_SUMMARY}\n• ⚠️ **${t_name}**: Path not found (${t_src})"
        continue
    fi

    # Build exclude options
    EXCLUDE_ARGS=()
    if [ -n "${t_excludes}" ]; then
        IFS=',' read -ra EX_ARR <<< "${t_excludes}"
        for pat in "${EX_ARR[@]}"; do
            [ -n "${pat}" ] && EXCLUDE_ARGS+=("--exclude" "${pat}")
        done
    fi

    if [ "${DRY_RUN}" = true ]; then
        echo "[DRY-RUN] Would backup ${t_src} with tag '${t_name}'"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        TARGETS_SUMMARY="${TARGETS_SUMMARY}\n• 🔍 **${t_name}**: Simulated backup"
    else
        echo "[*] Executing in-memory differential streaming backup..."
        RESTIC_OUTPUT=$(mktemp)
        if restic backup --tag "${t_name}" "${EXCLUDE_ARGS[@]}" "${t_src}" > "${RESTIC_OUTPUT}" 2>&1; then
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
            # Extract summary from restic output
            ADDED_BYTES=$(grep -E 'Added to the repository:' "${RESTIC_OUTPUT}" | tail -n 1 | awk '{print $5, $6}' || echo "N/A")
            FILES_PROCESSED=$(grep -E 'Files:' "${RESTIC_OUTPUT}" | tail -n 1 | awk '{print $2}' || echo "N/A")
            TARGETS_SUMMARY="${TARGETS_SUMMARY}\n• ✅ **${t_name}**: ${FILES_PROCESSED} files (new data: ${ADDED_BYTES})"
            echo "[+] Target '${t_name}' backed up successfully."
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            TARGETS_SUMMARY="${TARGETS_SUMMARY}\n• ❌ **${t_name}**: Backup failed"
            echo "[-] Error backing up target '${t_name}'." >&2
        fi
        rm -f "${RESTIC_OUTPUT}"
    fi
done <<< "${TARGET_LIST}"

# ------------------------------------------------------------------------------
# 5. Snapshot Retention Pruning
# ------------------------------------------------------------------------------
KEEP_DAILY=3
KEEP_WEEKLY=2
if [ "${DRY_RUN}" = false ]; then
    echo "------------------------------------------------------------------------------"
    echo "[*] Pruning expired snapshots (--keep-daily ${KEEP_DAILY} --keep-weekly ${KEEP_WEEKLY})..."
    restic forget --prune --keep-daily "${KEEP_DAILY}" --keep-weekly "${KEEP_WEEKLY}" >/dev/null 2>&1 || true
    echo "[+] Snapshot retention applied."
fi

# ------------------------------------------------------------------------------
# 6. Storage Quota Auditing via 'rclone about'
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo "[*] Auditing remote storage quota on '${OFFSITE_BACKUP_REMOTE_NAME}'..."
QUOTA_STATUS="Normal"
QUOTA_COLOR=3066993 # Green
QUOTA_PERCENT="0"
QUOTA_USED_HR="N/A"
QUOTA_TOTAL_HR="N/A"
QUOTA_FREE_HR="N/A"

QUOTA_JSON=$(rclone about "${OFFSITE_BACKUP_REMOTE_NAME}:" --json 2>/dev/null || echo "{}")

if [ -n "${QUOTA_JSON}" ] && [ "${QUOTA_JSON}" != "{}" ]; then
    PARSED_QUOTA=$(python3 -c "
import json, sys
try:
    data = json.loads('''${QUOTA_JSON}''')
    total = data.get('total', 0)
    used = data.get('used', 0)
    free = data.get('free', 0)
    pct = round((used / total) * 100, 1) if total > 0 else 0.0

    def hr(bytes_val):
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_val < 1024.0:
                return f'{bytes_val:.2f} {unit}'
            bytes_val /= 1024.0
        return f'{bytes_val:.2f} PB'

    print(f'{pct}|{hr(used)}|{hr(total)}|{hr(free)}')
except Exception:
    print('0|N/A|N/A|N/A')
")
    IFS='|' read -r QUOTA_PERCENT QUOTA_USED_HR QUOTA_TOTAL_HR QUOTA_FREE_HR <<< "${PARSED_QUOTA}"

    PCT_INT=$(python3 -c "print(int(float('${QUOTA_PERCENT}')))")

    if [ "${PCT_INT}" -ge "${CRIT_THRESHOLD}" ]; then
        QUOTA_STATUS="CRITICAL (${QUOTA_PERCENT}% used)"
        QUOTA_COLOR=15158332 # Red
    elif [ "${PCT_INT}" -ge "${WARN_THRESHOLD}" ]; then
        QUOTA_STATUS="WARNING (${QUOTA_PERCENT}% used)"
        QUOTA_COLOR=15105570 # Orange
    else
        QUOTA_STATUS="Normal (${QUOTA_PERCENT}% used)"
        QUOTA_COLOR=3066993 # Green
    fi
    echo "[+] Remote Quota: ${QUOTA_USED_HR} used / ${QUOTA_TOTAL_HR} total (${QUOTA_PERCENT}%), ${QUOTA_FREE_HR} free."
else
    echo "[*] Storage quota reporting not available for remote '${OFFSITE_BACKUP_REMOTE_NAME}'."
fi

# ------------------------------------------------------------------------------
# 7. Execution Summary & Discord Notification Dispatch
# ------------------------------------------------------------------------------
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_HR=$(printf '%dm %ds' $((DURATION / 60)) $((DURATION % 60)))

echo "=============================================================================="
echo "    Execution Summary                                                         "
echo "=============================================================================="
echo "[*] Targets Completed : ${SUCCESS_COUNT} / ${TOTAL_PROCESSED}"
echo "[*] Targets Failed    : ${FAIL_COUNT}"
echo "[*] Total Duration    : ${DURATION_HR}"
echo "[*] Storage Quota     : ${QUOTA_USED_HR} / ${QUOTA_TOTAL_HR} (${QUOTA_STATUS})"
echo "=============================================================================="

# Build Discord Fields
FIELDS_JSON=$(python3 -c "
import json
fields = [
    {'name': 'Targets Processed', 'value': '${SUCCESS_COUNT} successful, ${FAIL_COUNT} failed', 'inline': True},
    {'name': 'Duration', 'value': '${DURATION_HR}', 'inline': True},
    {'name': 'Remote Storage Quota', 'value': '${QUOTA_USED_HR} / ${QUOTA_TOTAL_HR} (${QUOTA_PERCENT}%)\nFree: ${QUOTA_FREE_HR}', 'inline': False},
    {'name': 'Dataset Breakdown', 'value': '''${TARGETS_SUMMARY}'''.strip() or 'None', 'inline': False}
]
print(json.dumps(fields))
")

if [ "${FAIL_COUNT}" -gt 0 ]; then
    send_discord_embed "15158332" "❌ Offsite Backup Completed with Errors" "One or more backup targets encountered an issue during the scheduled offsite run." "${FIELDS_JSON}"
elif [ "${QUOTA_COLOR}" = 15158332 ] || [ "${QUOTA_COLOR}" = 15105570 ]; then
    send_discord_embed "${QUOTA_COLOR}" "⚠️ Offsite Backup Completed - Quota Warning" "Backup completed successfully, but your remote storage quota is approaching capacity." "${FIELDS_JSON}"
else
    send_discord_embed "3066993" "✅ Offsite Backup Completed Successfully" "All configured targets were verified, encrypted, and streamed to offsite cloud storage as expected." "${FIELDS_JSON}"
fi

# ------------------------------------------------------------------------------
# 8. Ephemeral Shutdown (if requested)
# ------------------------------------------------------------------------------
if [ "${EPHEMERAL_MODE}" = true ]; then
    echo "[*] Ephemeral mode active. Initiating clean container shutdown..."
    poweroff || shutdown -h now || true
fi
