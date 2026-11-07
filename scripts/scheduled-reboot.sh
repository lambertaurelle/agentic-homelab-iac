#!/usr/bin/env bash
# ==============================================================================
# Homelab Safety-First Scheduled Rolling Reboot Engine
# ==============================================================================
# Target Schedule:
#   - Node 1 (node-1): Sunday 05:15 AM
#   - Node 2 (node-2): Monday 05:15 AM
#
# Pre-Reboot Safety Guards:
#   1. Peer Node Ping Reachability: Verifies peer host is alive.
#   2. Peer AdGuard DNS Resolution:
#      - On node-1: Validates DNS query against secondary AdGuard.
#      - On node-2: Validates DNS query against primary AdGuard.
#   3. Active Operations Check (VZDump backup, CT 602 offsite streaming, update-cluster-stack.sh).
#   4. Aborts safely if peer or operations unhealthy and alerts via Discord.
#   5. If all guards pass, executes disk sync & systemctl reboot.
#   6. Supports --dry-run / --check to test health checks without rebooting.
# ==============================================================================
set -euo pipefail

# Dynamic configuration sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${SCRIPT_DIR}/lib/common.sh" ]; then
    # shellcheck disable=SC1091
    . "${SCRIPT_DIR}/lib/common.sh"
fi

if [ -f "${REPO_ROOT}/secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/secrets.env"
elif [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

LOG_FILE="/var/log/homelab-reboot.log"
DRY_RUN=false
FORCE_NODE=""
TEST_DOMAIN="google.com"

# Configuration map
NODE1_IP="${NODE1_IP:-10.0.0.10}"
NODE2_IP="${NODE2_IP:-10.0.0.20}"
PRIMARY_ADGUARD_IP="${PRIMARY_ADGUARD_IP:-10.0.0.201}"
SECONDARY_ADGUARD_IP="${SECONDARY_ADGUARD_IP:-10.0.0.202}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--check|-n)
            DRY_RUN=true
            shift
            ;;
        --node)
            FORCE_NODE="$2"
            shift 2
            ;;
        --domain)
            TEST_DOMAIN="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --dry-run, --check, -n   Run health checks without triggering reboot"
            echo "  --node <node-1|node-2>   Explicitly specify host identity (node-1 or node-2)"
            echo "  --domain <domain>        Domain name for peer DNS test (default: google.com)"
            echo "  -h, --help               Show this help message"
            exit 0
            ;;
        *)
            echo "[-] Unknown option: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# Ensure log directory and file
mkdir -p "$(dirname "${LOG_FILE}")"
touch "${LOG_FILE}" 2>/dev/null || true

# Logging helper
log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[$timestamp] $1"
    echo -e "$message"
    if [ -w "${LOG_FILE}" ]; then
        echo -e "$message" >> "${LOG_FILE}"
    fi
}

log_header() {
    log "=============================================================================="
    log "  $1"
    log "=============================================================================="
}

DISCORD_WEBHOOK="${DISCORD_MONITORING_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}"

send_reboot_abort_alert() {
    local reason_title="$1"
    local reason_desc="$2"
    local color="${3:-15105570}" # Orange by default

    if [ -z "${DISCORD_WEBHOOK}" ] || [ "${DRY_RUN}" = true ]; then
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
        'fields': [
            {'name': 'Node', 'value': sys.argv[4], 'inline': True},
            {'name': 'Scheduled Time', 'value': '05:15 AM', 'inline': True}
        ],
        'footer': {'text': 'Homelab High Availability Engine • scheduled-reboot.sh'}
    }]
}
print(json.dumps(data))
" "${reason_title}" "${reason_desc}" "${color}" "${CURRENT_NODE}" 2>/dev/null || true)

    if [ -n "${payload}" ]; then
        curl -s -S -X POST -H "Content-Type: application/json" -H "User-Agent: Homelab-Ops/1.0" -d "${payload}" "${DISCORD_WEBHOOK}" >/dev/null 2>&1 || true
    fi
}

# Determine Current Node
if [ -n "${FORCE_NODE}" ]; then
    CURRENT_NODE="${FORCE_NODE}"
else
    HOST_DETECT=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")
    if [[ "$HOST_DETECT" == "node-1" ]] || [[ "$HOST_DETECT" == "proxmox" ]] || [[ "$HOST_DETECT" == "${UTILITY_NODE_NAME:-node-1}" ]] || (ip -o addr show 2>/dev/null | grep -qwF "${NODE1_IP}"); then
        CURRENT_NODE="node-1"
    elif [[ "$HOST_DETECT" == "node-2" ]] || [[ "$HOST_DETECT" == "tuxmox" ]] || [[ "$HOST_DETECT" == "${COMPUTE_NODE_NAME:-node-2}" ]] || (ip -o addr show 2>/dev/null | grep -qwF "${NODE2_IP}"); then
        CURRENT_NODE="node-2"
    else
        log "[-] ERROR: Unable to determine node identity (hostname: '${HOST_DETECT}')."
        log "[-] Specify with '--node node-1' or '--node node-2'."
        exit 1
    fi
fi

# Configure Peer Parameters based on Current Node
if [[ "${CURRENT_NODE}" == "node-1" ]]; then
    CURRENT_IP="${NODE1_IP}"
    PEER_NODE="node-2"
    PEER_IP="${NODE2_IP}"
    PEER_ADGUARD_IP="${SECONDARY_ADGUARD_IP}"
    SCHEDULED_DAY="Sunday"
elif [[ "${CURRENT_NODE}" == "node-2" ]]; then
    CURRENT_IP="${NODE2_IP}"
    PEER_NODE="node-1"
    PEER_IP="${NODE1_IP}"
    PEER_ADGUARD_IP="${PRIMARY_ADGUARD_IP}"
    SCHEDULED_DAY="Monday"
else
    log "[-] ERROR: Unrecognized node name '${CURRENT_NODE}'."
    exit 1
fi

if [ "$DRY_RUN" = true ]; then
    log_header "SCHEDULED REBOOT SAFETY CHECK [DRY-RUN]"
else
    log_header "SCHEDULED REBOOT EXECUTION [LIVE]"
fi

log "[*] Current Host:  ${CURRENT_NODE} (${CURRENT_IP})"
log "[*] Target Peer:   ${PEER_NODE} (${PEER_IP})"
log "[*] Peer AdGuard:  ${PEER_ADGUARD_IP}"
log "[*] Target Day:    ${SCHEDULED_DAY} (05:15 AM)"

# ==============================================================================
# PRE-REBOOT SAFETY GUARDS
# ==============================================================================

# Guard 1: Peer Node Ping Reachability
log "[*] Guard 1/3: Testing peer node reachability (ping ${PEER_IP})..."
if ping -c 3 -W 2 "${PEER_IP}" >/dev/null 2>&1; then
    log "[+] Guard 1 PASSED: Peer host ${PEER_NODE} (${PEER_IP}) is responsive."
else
    log "[-] CRITICAL FAILURE: Guard 1 FAILED! Peer host ${PEER_NODE} (${PEER_IP}) is UNREACHABLE."
    log "[-] ABORTING REBOOT: Cluster high availability would be compromised."
    send_reboot_abort_alert "🚨 Scheduled Reboot Aborted on ${CURRENT_NODE}" \
        "Peer host **${PEER_NODE}** (${PEER_IP}) is unreachable. Reboot aborted to prevent total cluster split-brain." "15158332"
    exit 2
fi

# Guard 2: Peer AdGuard DNS Resolution
log "[*] Guard 2/3: Testing peer AdGuard DNS resolution (@${PEER_ADGUARD_IP} ${TEST_DOMAIN})..."
DNS_RESOLVED=false

if command -v dig >/dev/null 2>&1; then
    DNS_OUTPUT=$(dig @"${PEER_ADGUARD_IP}" "${TEST_DOMAIN}" +time=3 +tries=2 +short 2>/dev/null || true)
    if [ -n "${DNS_OUTPUT}" ]; then
        DNS_RESOLVED=true
        log "[+] DNS query resolved: $(echo "${DNS_OUTPUT}" | tr '\n' ' ')"
    fi
elif command -v nslookup >/dev/null 2>&1; then
    if nslookup -timeout=3 "${TEST_DOMAIN}" "${PEER_ADGUARD_IP}" >/dev/null 2>&1; then
        DNS_RESOLVED=true
    fi
fi

if [ "${DNS_RESOLVED}" = true ]; then
    log "[+] Guard 2 PASSED: Peer AdGuard instance (${PEER_ADGUARD_IP}) is actively serving DNS."
else
    log "[-] CRITICAL FAILURE: Guard 2 FAILED! Peer AdGuard (${PEER_ADGUARD_IP}) failed DNS resolution."
    log "[-] ABORTING REBOOT: DNS outage would occur if current node restarts."
    send_reboot_abort_alert "🚨 Scheduled Reboot Aborted on ${CURRENT_NODE}" \
        "Peer AdGuard DNS (**${PEER_ADGUARD_IP}**) failed query resolution. Reboot aborted to preserve LAN DNS availability." "15158332"
    exit 3
fi

# Guard 3: Active Operations Protection (VZDump, CT 602, and Updates)
log "[*] Guard 3/3: Verifying no active backups or updates in progress..."
ACTIVE_OP=""

if pgrep -x vzdump >/dev/null 2>&1; then
    ACTIVE_OP="Local VZDump snapshot backup is currently active"
elif pct status 602 2>/dev/null | grep -q 'running'; then
    ACTIVE_OP="Ephemeral offsite backup container (CT 602) is currently streaming to cloud"
elif pgrep -f update-cluster-stack.sh >/dev/null 2>&1; then
    ACTIVE_OP="Cluster update stack engine (update-cluster-stack.sh) is currently running"
fi

if [ -n "${ACTIVE_OP}" ]; then
    log "[-] CRITICAL FAILURE: Guard 3 FAILED! ${ACTIVE_OP}."
    log "[-] ABORTING REBOOT: Rebooting now would corrupt backups or disrupt updates."
    send_reboot_abort_alert "⚠️ Scheduled Reboot Postponed on ${CURRENT_NODE}" \
        "Reboot aborted because critical workload is active: **${ACTIVE_OP}**." "15105570"
    exit 4
fi
log "[+] Guard 3 PASSED: No active backup or update processes detected."

# ==============================================================================
# REBOOT INVOCATION
# ==============================================================================
log "[+] All Pre-Reboot Safety Guards PASSED successfully."

if [ "${DRY_RUN}" = true ]; then
    log "[DRY-RUN] Pre-flight checks successful. Reboot skipped because --dry-run was specified."
    log "=============================================================================="
    exit 0
fi

log "[*] Syncing filesystem buffers..."
sync

log "[*] Initiating system reboot on ${CURRENT_NODE}..."
log "=============================================================================="

# Gracefully trigger reboot
systemctl reboot
