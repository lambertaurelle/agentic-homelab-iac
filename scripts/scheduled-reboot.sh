#!/usr/bin/env bash
# ==============================================================================
# Homelab Safety-First Scheduled Rolling Reboot Engine
# ==============================================================================
# Target Schedule:
#   - Node 1 (node-1): Sunday 04:00 AM
#   - Node 2 (node-2): Monday 04:00 AM
#
# Pre-Reboot Safety Guards:
#   1. Peer Node Ping Reachability: Verifies peer host is alive.
#   2. Peer AdGuard DNS Resolution:
#      - On node-1: Validates DNS query against secondary AdGuard.
#      - On node-2: Validates DNS query against primary AdGuard.
#   3. Aborts safely if peer is unhealthy and logs error to /var/log/homelab-reboot.log.
#   4. If peer is healthy, executes disk sync & systemctl reboot.
#   5. Supports --dry-run / --check to test health checks without rebooting.
# ==============================================================================
set -euo pipefail

# Dynamic configuration sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
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

# Determine Current Node
if [ -n "${FORCE_NODE}" ]; then
    CURRENT_NODE="${FORCE_NODE}"
else
    HOST_DETECT=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")
    if [[ "$HOST_DETECT" == *"1"* ]] || [[ "$HOST_DETECT" == "node-1"* ]] || ip addr show 2>/dev/null | grep -q "${NODE1_IP}"; then
        CURRENT_NODE="node-1"
    elif [[ "$HOST_DETECT" == *"2"* ]] || [[ "$HOST_DETECT" == "node-2"* ]] || ip addr show 2>/dev/null | grep -q "${NODE2_IP}"; then
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
log "[*] Target Day:    ${SCHEDULED_DAY} (04:00 AM)"

# ==============================================================================
# PRE-REBOOT SAFETY GUARDS
# ==============================================================================

# Guard 1: Peer Node Ping Reachability
log "[*] Guard 1/2: Testing peer node reachability (ping ${PEER_IP})..."
if ping -c 3 -W 2 "${PEER_IP}" >/dev/null 2>&1; then
    log "[+] Guard 1 PASSED: Peer host ${PEER_NODE} (${PEER_IP}) is responsive."
else
    log "[-] CRITICAL FAILURE: Guard 1 FAILED! Peer host ${PEER_NODE} (${PEER_IP}) is UNREACHABLE."
    log "[-] ABORTING REBOOT: Cluster high availability would be compromised."
    exit 2
fi

# Guard 2: Peer AdGuard DNS Resolution
log "[*] Guard 2/2: Testing peer AdGuard DNS resolution (@${PEER_ADGUARD_IP} ${TEST_DOMAIN})..."
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
    exit 3
fi

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
