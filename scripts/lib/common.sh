#!/usr/bin/env bash
# ==============================================================================
# Homelab Common Automation Library (scripts/lib/common.sh)
# ==============================================================================
# Provides shared node resolution, SSH execution, container inspection, and
# logging utilities across all homelab automation engines.
# ==============================================================================

# Guard against double inclusion
if [ -n "${_HOMELAB_COMMON_SH_LOADED:-}" ]; then
    # shellcheck disable=SC2317
    return 0 2>/dev/null || exit 0
fi
_HOMELAB_COMMON_SH_LOADED=1

# ------------------------------------------------------------------------------
# Logging Macro
# ------------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_err() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [-] $*" >&2
}

# ------------------------------------------------------------------------------
# Node & IP Resolution
# ------------------------------------------------------------------------------
NODE1_IP="${NODE1_IP:-${PROXMOX_NODE_IP:-10.0.0.10}}"
NODE2_IP="${NODE2_IP:-${TUXMOX_NODE_IP:-10.0.0.20}}"
UTILITY_NODE_NAME="${UTILITY_NODE_NAME:-node-1}"
COMPUTE_NODE_NAME="${COMPUTE_NODE_NAME:-node-2}"

resolve_node_ip() {
    local target="$1"
    case "${target}" in
        node-1|"${UTILITY_NODE_NAME}"|proxmox)
            echo "${NODE1_IP}"
            ;;
        node-2|"${COMPUTE_NODE_NAME}"|tuxmox)
            echo "${NODE2_IP}"
            ;;
        *)
            if [[ "${target}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                echo "${target}"
            elif grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+.*[[:<:]]${target}[[:>:]]" /etc/hosts 2>/dev/null; then
                awk -v h="${target}" '$0 ~ h {print $1; exit}' /etc/hosts
            else
                echo "${target}"
            fi
            ;;
    esac
}

is_local_node() {
    local node="$1"
    local node_ip
    node_ip=$(resolve_node_ip "${node}")

    local current_host
    current_host=$(hostname -s 2>/dev/null || hostname)
    if [ "${current_host}" = "${node}" ]; then
        return 0
    fi

    if ip -o addr show 2>/dev/null | grep -qwF "${node_ip}"; then
        return 0
    fi

    return 1
}

# ------------------------------------------------------------------------------
# Remote / Local Hypervisor Execution Wrapper
# ------------------------------------------------------------------------------
run_on_node() {
    local node="$1"
    local cmd="$2"
    local node_ip
    node_ip=$(resolve_node_ip "${node}")

    if is_local_node "${node}"; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "root@${node_ip}" "${cmd}"
    fi
}

# ------------------------------------------------------------------------------
# Container Runtime Inspection Helpers
# ------------------------------------------------------------------------------
is_ct_running() {
    local node="$1"
    local ctid="$2"
    local status
    status=$(run_on_node "${node}" "pct status ${ctid} 2>/dev/null || true")
    echo "${status}" | grep -q "status: running"
}

run_in_ct() {
    local node="$1"
    local ctid="$2"
    local cmd="$3"
    run_on_node "${node}" "pct exec ${ctid} -- bash -c $(printf '%q' "${cmd}")"
}

# ------------------------------------------------------------------------------
# Dynamic Container Location & Metadata Lookup (Cluster JSON)
# ------------------------------------------------------------------------------
ct_location() {
    local ctid="$1"
    local master_node="${2:-${NODE1_IP}}"

    local cluster_json
    cluster_json=$(run_on_node "${master_node}" "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null || true")

    if [ -n "${cluster_json}" ]; then
        python3 -c '
import sys, json
try:
    resources = json.loads(sys.argv[1])
    target_ctid = int(sys.argv[2])
    for item in resources:
        if item.get("vmid") == target_ctid and item.get("type") in ("lxc", "qemu"):
            print(f"{item.get(\x27node\x27, \x27\x27)}|{item.get(\x27status\x27, \x27\x27)}")
            sys.exit(0)
except Exception:
    pass
sys.exit(1)
' "${cluster_json}" "${ctid}" 2>/dev/null || true
    fi
}
