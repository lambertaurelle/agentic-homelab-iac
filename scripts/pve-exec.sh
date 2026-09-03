#!/usr/bin/env bash
# ==============================================================================
# Proxmox VE Node Command Execution Wrapper
# ==============================================================================
# Transparently executes commands on Proxmox hypervisor nodes (node-1 / node-2).
#
# When executed inside the Management Workspace (CT 900 `mgmt-devops`):
#   Routes commands via passwordless SSH to the target hypervisor host.
# When executed directly on a Proxmox hypervisor host:
#   Detects local IP ownership and executes commands directly in bash.
#
# Usage:
#   ./scripts/pve-exec.sh [node-1|node-2|<ip-or-host>] <command...>
#
# Examples:
#   ./scripts/pve-exec.sh node-1 pct status 602
#   ./scripts/pve-exec.sh node-1 pvecm status
#   ./scripts/pve-exec.sh node-2 pct list
#   ./scripts/pve-exec.sh pct status 602         (Defaults to node-1)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load environment configuration if available
if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

# Fallback node definitions
NODE1_IP="${NODE1_IP:-}"
NODE2_IP="${NODE2_IP:-}"

if [ -z "${NODE1_IP}" ]; then
    if grep -q "proxmox" /etc/hosts 2>/dev/null; then
        NODE1_IP="proxmox"
    else
        NODE1_IP="10.0.0.10"
    fi
fi

if [ -z "${NODE2_IP}" ]; then
    if grep -q "tuxmox" /etc/hosts 2>/dev/null; then
        NODE2_IP="tuxmox"
    else
        NODE2_IP="10.0.0.11"
    fi
fi

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 [node-1|node-2|<ip-or-host>] <command...>"
    echo "Examples:"
    echo "  $0 node-1 pct status 602"
    echo "  $0 node-1 pvecm status"
    echo "  $0 node-2 pct list"
    echo "  $0 pct status 602         # Defaults to node-1"
    exit 1
fi

TARGET_NODE="$1"
CMD_ARGS=()

case "${TARGET_NODE}" in
    node-1|node1|pve1|master|utility)
        TARGET_HOST="${NODE1_IP}"
        shift
        CMD_ARGS=("$@")
        ;;
    node-2|node2|pve2|compute)
        TARGET_HOST="${NODE2_IP}"
        shift
        CMD_ARGS=("$@")
        ;;
    *)
        # Check if first arg looks like an IP address or known host in /etc/hosts
        if [[ "${TARGET_NODE}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || grep -qE "(^|\s)${TARGET_NODE}(\s|$)" /etc/hosts 2>/dev/null; then
            TARGET_HOST="${TARGET_NODE}"
            shift
            CMD_ARGS=("$@")
        else
            # Default to node-1 and use all arguments as the command
            TARGET_HOST="${NODE1_IP}"
            CMD_ARGS=("$@")
        fi
        ;;
esac

if [ "${#CMD_ARGS[@]}" -eq 0 ]; then
    echo "[-] Error: No command specified to execute on ${TARGET_HOST}."
    exit 1
fi

# Determine if the target host is local to this environment
is_local() {
    local host="$1"
    if [[ "${host}" == "localhost" ]] || [[ "${host}" == "127.0.0.1" ]]; then
        return 0
    fi
    if ip addr show 2>/dev/null | grep -Fwq "${host}"; then
        return 0
    fi
    return 1
}

# Execute command
if is_local "${TARGET_HOST}"; then
    exec "${CMD_ARGS[@]}"
else
    # Run via SSH with strict batch mode to avoid hanging on password prompts
    exec ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "root@${TARGET_HOST}" "${CMD_ARGS[@]}"
fi
