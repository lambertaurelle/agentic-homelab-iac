#!/usr/bin/env bash
# ==============================================================================
# Homelab Declarative Docker Stack Reconciler (GitOps Engine)
# ==============================================================================
# Converges guest LXC container states to match Git-declared Docker Compose stacks:
#   1. Pre-flight check: Verifies container is online (respects started = false)
#   2. Secret validation: Auto-hydrates .env from bootstrap-secrets.sh if missing
#   3. Configuration sync: Idempotently syncs compose files to /opt/<app>/
#   4. Declarative apply: Executes `docker compose up -d --remove-orphans`
#
# Usage:
#   ./scripts/reconcile-stacks.sh --app lecuchon
#   ./scripts/reconcile-stacks.sh --all
#   ./scripts/reconcile-stacks.sh --dry-run --app immich
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source secrets/configuration if present
if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

NODE1_HOST="${NODE1_IP:-10.0.0.10}"
NODE2_HOST="${NODE2_IP:-10.0.0.20}"

TARGET_APP=""
RECONCILE_ALL=false
DRY_RUN=false
TARGET_NODE="all"

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app|-a)
            TARGET_APP="$2"
            shift 2
            ;;
        --all)
            RECONCILE_ALL=true
            shift
            ;;
        --dry-run|-n)
            DRY_RUN=true
            shift
            ;;
        --node)
            TARGET_NODE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --app <name>             Target specific application stack (e.g. lecuchon, immich)"
            echo "  --all                    Reconcile all declared application stacks"
            echo "  --dry-run, -n            Simulate reconciliation without applying changes"
            echo "  --node <node-1|node-2>   Filter by target Proxmox node (default: all)"
            echo "  -h, --help               Show this help message"
            exit 0
            ;;
        *)
            echo "[-] Error: Unknown option '$1'. Use --help for usage." >&2
            exit 1
            ;;
    esac
done

if [ -z "${TARGET_APP}" ] && [ "${RECONCILE_ALL}" = false ]; then
    echo "[-] Error: Please specify a target stack with --app <name> or reconcile all with --all." >&2
    exit 1
fi

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $1"
}

log_header() {
    echo "=============================================================================="
    echo "  $1"
    echo "=============================================================================="
}

run_on_node() {
    local node_ip="$1"
    local cmd="$2"

    if ip addr show 2>/dev/null | grep -q "${node_ip}" || [[ "$node_ip" == "localhost" ]] || [[ "$node_ip" == "127.0.0.1" ]]; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 "root@${node_ip}" "${cmd}"
    fi
}

run_in_ct() {
    local node_ip="$1"
    local ct_id="$2"
    local cmd="$3"
    run_on_node "${node_ip}" "pct exec ${ct_id} -- bash -c '${cmd//\'/\'\\\'\'}'"
}

is_ct_running() {
    local node_ip="$1"
    local ct_id="$2"
    local status
    status=$(run_on_node "${node_ip}" "pct status ${ct_id} 2>/dev/null || true")
    if echo "${status}" | grep -q "status: running"; then
        return 0
    fi
    return 1
}

# Resolve target metadata for a given stack name
# Output format: CTID NODE_NAME NODE_IP STACK_DIR
resolve_stack_metadata() {
    local app="$1"
    local stack_dir=""
    local ctid=""
    local node_name=""
    local node_ip=""

    # Locate stack directory in repo
    if [ -d "${REPO_ROOT}/stacks/instance/${app}" ]; then
        stack_dir="${REPO_ROOT}/stacks/instance/${app}"
    elif [ -d "${REPO_ROOT}/stacks/${app}" ]; then
        stack_dir="${REPO_ROOT}/stacks/${app}"
    else
        echo ""
        return 1
    fi

    # Known application mappings
    case "${app}" in
        monitoring)
            ctid="901"
            node_name="node-1"
            node_ip="${NODE1_HOST}"
            ;;
        offsite-backup)
            ctid="602"
            node_name="node-1"
            node_ip="${NODE1_HOST}"
            ;;
        seedbox)
            ctid="201"
            node_name="node-2"
            node_ip="${NODE2_HOST}"
            ;;
        immich)
            ctid="301"
            node_name="node-2"
            node_ip="${NODE2_HOST}"
            ;;
        teamspeak)
            ctid="401"
            node_name="node-2"
            node_ip="${NODE2_HOST}"
            ;;
        lecuchon)
            ctid="701"
            node_name="node-2"
            node_ip="${NODE2_HOST}"
            ;;
        workspace-sync)
            ctid="702"
            node_name="node-2"
            node_ip="${NODE2_HOST}"
            ;;
        *)
            # Fallback: scan tofu/ct-${app}.tf for vm_id and node_name
            local tf_file="${REPO_ROOT}/tofu/ct-${app}.tf"
            if [ -f "${tf_file}" ]; then
                ctid=$(grep -E 'vm_id\s*=' "${tf_file}" | head -n1 | grep -o '[0-9]\+' || true)
                if grep -q 'node-1' "${tf_file}"; then
                    node_name="node-1"
                    node_ip="${NODE1_HOST}"
                else
                    node_name="node-2"
                    node_ip="${NODE2_HOST}"
                fi
            fi
            ;;
    esac

    if [ -z "${ctid}" ]; then
        echo ""
        return 1
    fi

    echo "${ctid} ${node_name} ${node_ip} ${stack_dir}"
}

reconcile_single_stack() {
    local app="$1"
    local meta
    if ! meta=$(resolve_stack_metadata "${app}"); then
        log "[-] Error: Unable to resolve metadata or locate stack folder for '${app}'."
        return 1
    fi

    read -r ctid node_name node_ip stack_dir <<< "${meta}"

    # Filter by node if requested
    if [ "${TARGET_NODE}" != "all" ] && [ "${TARGET_NODE}" != "${node_name}" ]; then
        return 0
    fi

    log_header "Reconciling Stack: ${app} (CT ${ctid} on ${node_name})"

    # 1. Check if container is running
    if ! is_ct_running "${node_ip}" "${ctid}"; then
        log "[!] Container CT ${ctid} (${app}) is stopped (declared started = false). Gracefully skipping."
        return 0
    fi

    # 2. Check and hydrate .env if missing
    if [ ! -f "${stack_dir}/.env" ] && [ -f "${stack_dir}/.env.example" ]; then
        log "[*] .env missing in ${stack_dir}. Running secrets bootstrapper..."
        "${REPO_ROOT}/scripts/bootstrap-secrets.sh" >/dev/null
    fi

    # 3. Dry-run evaluation
    if [ "${DRY_RUN}" = true ]; then
        log "[DRY-RUN] Verified CT ${ctid} (${app}) is running."
        log "[DRY-RUN] Would sync stack files from ${stack_dir} to CT ${ctid}:/opt/${app}/"
        log "[DRY-RUN] Would execute 'docker compose up -d --remove-orphans' inside CT ${ctid}"
        return 0
    fi

    # 4. Ensure destination directory exists inside container
    run_in_ct "${node_ip}" "${ctid}" "mkdir -p /opt/${app}"

    # 5. Synchronize stack directory into container
    log "[*] Synchronizing declarative configuration to CT ${ctid}:/opt/${app}..."
    tar -C "${stack_dir}" \
        --exclude='.git*' \
        --exclude='__pycache__' \
        --exclude='*.pyc' \
        -cf - . | run_on_node "${node_ip}" "pct exec ${ctid} -- tar -C /opt/${app} -xf -"

    # 6. Converge container stack using docker compose up
    log "[*] Applying declarative Compose state (docker compose up -d --remove-orphans)..."
    run_in_ct "${node_ip}" "${ctid}" "
        cd /opt/${app}
        docker compose up -d --remove-orphans
        docker image prune -f >/dev/null 2>&1 || true
    "

    # 7. Verification check
    log "[+] Checking running services for ${app}:"
    run_in_ct "${node_ip}" "${ctid}" "cd /opt/${app} && docker compose ps"
    log "[+] Stack '${app}' converged to desired state successfully!"
}

# Main execution loop
log_header "Homelab Declarative Stack Reconciler"

if [ "${RECONCILE_ALL}" = true ]; then
    # Discover all stacks
    for d in "${REPO_ROOT}"/stacks/*/ "${REPO_ROOT}"/stacks/instance/*/; do
        [ -d "$d" ] || continue
        app_name=$(basename "$d")
        # Exclude internal / non-stack folders
        [[ "$app_name" == "instance" || "$app_name" == "monitoring" && "$d" == *"instance"* ]] && continue
        [ -f "${d}docker-compose.yml" ] || [ -f "${d}docker-compose.yaml" ] || continue

        reconcile_single_stack "${app_name}" || true
    done
else
    reconcile_single_stack "${TARGET_APP}"
fi

log_header "Reconciliation Complete"
