#!/usr/bin/env bash
# ==============================================================================
# Homelab Automated Cluster Stack & LXC Container Update Engine
# ==============================================================================
# Scope:
#   1. Proxmox VE Debian 12 host package upgrades
#   2. Dynamic OS package upgrades for all running LXC containers (via pct list)
#   3. Baseline native application updates:
#      - AdGuard Home & adguardhome-sync
#      - Cloudflared Tunnel
#      - Antigravity CLI & Remote Control Daemon
#   4. Extension hook invocation (scripts/instance/update-instance-workloads.sh)
#   5. Dynamic Docker Compose stack discovery, pull, upgrade & prune across /opt/*/
#   6. Logging to /var/log/homelab-updates.log with --dry-run / --check support
# ==============================================================================
set -euo pipefail

# Dynamic configuration sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

# Configuration
LOG_FILE="/var/log/homelab-updates.log"
NODE1_HOST="${NODE1_IP:-10.0.0.10}"
NODE2_HOST="${NODE2_IP:-10.0.0.20}"

DRY_RUN=false
TARGET_NODE="all"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--check|-n)
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
            echo "  --dry-run, --check, -n   Simulate updates and check status without applying changes"
            echo "  --node <node-1|node-2|local|all>  Target specific node (default: all)"
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

# Ensure log file and directory exist
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

# Node execution helper
run_on_node() {
    local node_ip="$1"
    local cmd="$2"

    if ip addr show 2>/dev/null | grep -q "${node_ip}" || [[ "$node_ip" == "localhost" ]] || [[ "$node_ip" == "127.0.0.1" ]]; then
        bash -c "${cmd}"
    else
        local timeout_sec="${CONNECT_TIMEOUT:-3}"
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout="${timeout_sec}" "root@${node_ip}" "${cmd}"
    fi
}

# Container execution helper
run_in_ct() {
    local node_ip="$1"
    local ct_id="$2"
    local cmd="$3"
    run_on_node "${node_ip}" "pct exec ${ct_id} -- bash -c '${cmd//\'/\'\\\'\'}'"
}

# Container status helper
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

# Dynamic running container query helper
get_running_cts() {
    local node_ip="$1"
    local cts=""

    if ! run_on_node "${node_ip}" "true" >/dev/null 2>&1; then
        return 0
    fi

    cts=$(run_on_node "${node_ip}" "pct list 2>/dev/null | awk 'NR>1 && \$2==\"running\" {print \$1}'" 2>/dev/null || true)
    if [ -n "${cts}" ]; then
        echo "${cts}"
    fi
}

# Mode banner
if [ "$DRY_RUN" = true ]; then
    log_header "HOMELAB CLUSTER UPDATE ENGINE [DRY-RUN / SIMULATION MODE]"
    log "[!] DRY_RUN enabled. No packages, images, or configurations will be modified."
else
    log_header "HOMELAB AUTOMATED CLUSTER UPDATE ENGINE"
fi

PROCESS_NODE1=false
PROCESS_NODE2=false

case "$TARGET_NODE" in
    node-1|1)
        PROCESS_NODE1=true
        ;;
    node-2|2)
        PROCESS_NODE2=true
        ;;
    local)
        if ip addr show 2>/dev/null | grep -q "${NODE2_HOST}"; then
            PROCESS_NODE2=true
        else
            PROCESS_NODE1=true
        fi
        ;;
    all|*)
        PROCESS_NODE1=true
        PROCESS_NODE2=true
        ;;
esac

# ==============================================================================
# 1. Update Proxmox VE Hosts (Hypervisors)
# ==============================================================================
log_header "STAGE 1: Proxmox VE Hypervisor Host Updates"

update_pve_host() {
    local node_name="$1"
    local node_ip="$2"

    log "[*] Connecting to Proxmox VE node '${node_name}' (${node_ip})..."

    if ! run_on_node "${node_ip}" "true" >/dev/null 2>&1; then
        log "[!] Warning: Proxmox node '${node_name}' at ${node_ip} is unreachable. Skipping host update."
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Node '${node_name}': Checking available Debian/PVE package updates..."
        local upgradable_list
        upgradable_list=$(run_on_node "${node_ip}" "apt-get update -q >/dev/null 2>&1 && apt-get -s dist-upgrade | grep -E '^[0-9]+ upgraded' || echo '0 upgraded'")
        log "[DRY-RUN] Node '${node_name}': ${upgradable_list}"
    else
        log "[*] Updating package repositories and upgrading packages on '${node_name}'..."
        if run_on_node "${node_ip}" "export DEBIAN_FRONTEND=noninteractive && apt-get update -q && apt-get dist-upgrade -y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" && apt-get autoremove -y -q && apt-get clean"; then
            log "[+] Host packages on node '${node_name}' updated successfully."
        else
            log "[-] Error: Package upgrade on '${node_name}' reported a non-zero exit code."
        fi
    fi
}

if [ "$PROCESS_NODE1" = true ]; then
    update_pve_host "node-1" "${NODE1_HOST}"
fi

if [ "$PROCESS_NODE2" = true ]; then
    update_pve_host "node-2" "${NODE2_HOST}"
fi

# ==============================================================================
# 2. Dynamic Guest OS Updates across all LXC Containers
# ==============================================================================
log_header "STAGE 2: Guest OS Updates for Running Containers"

update_lxc_container() {
    local node_name="$1"
    local node_ip="$2"
    local ct_id="$3"

    if ! is_ct_running "${node_ip}" "${ct_id}"; then
        log "[!] CT ${ct_id} on ${node_name} is not running. Skipping."
        return 0
    fi

    local ct_name
    ct_name=$(run_on_node "${node_ip}" "pct config ${ct_id} 2>/dev/null | grep -E '^hostname:' | awk '{print \$2}' || echo 'ct-${ct_id}'")

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] CT ${ct_id} (${ct_name} on ${node_name}): Checking package updates..."
        local ct_upgradable
        ct_upgradable=$(run_in_ct "${node_ip}" "${ct_id}" "apt-get update -q >/dev/null 2>&1 && apt-get -s dist-upgrade | grep -E '^[0-9]+ upgraded' || echo '0 upgraded'")
        log "[DRY-RUN] CT ${ct_id} (${ct_name}): ${ct_upgradable}"
    else
        log "[*] Updating CT ${ct_id} (${ct_name} on ${node_name})..."
        if run_in_ct "${node_ip}" "${ct_id}" "export DEBIAN_FRONTEND=noninteractive && apt-get update -q && apt-get dist-upgrade -y -o Dpkg::Options::=\"--force-confdef\" -o Dpkg::Options::=\"--force-confold\" && apt-get autoremove -y -q && apt-get clean"; then
            log "[+] CT ${ct_id} (${ct_name}) updated successfully."
        else
            log "[!] Warning: CT ${ct_id} (${ct_name}) OS package update reported non-zero status. Continuing with next container..."
        fi
    fi
}

ACTIVE_NODE1_CTS=()
ACTIVE_NODE2_CTS=()

if [ "$PROCESS_NODE1" = true ]; then
    log "[*] Discovering active containers on Utility Node (${NODE1_HOST})..."
    mapfile -t ACTIVE_NODE1_CTS < <(get_running_cts "${NODE1_HOST}")
    log "[+] Active containers on node-1: ${ACTIVE_NODE1_CTS[*]:-none}"
    for ct in "${ACTIVE_NODE1_CTS[@]}"; do
        [ -z "${ct}" ] && continue
        update_lxc_container "node-1" "${NODE1_HOST}" "${ct}"
    done
fi

if [ "$PROCESS_NODE2" = true ]; then
    log "[*] Discovering active containers on Compute Node (${NODE2_HOST})..."
    mapfile -t ACTIVE_NODE2_CTS < <(get_running_cts "${NODE2_HOST}")
    log "[+] Active containers on node-2: ${ACTIVE_NODE2_CTS[*]:-none}"
    for ct in "${ACTIVE_NODE2_CTS[@]}"; do
        [ -z "${ct}" ] && continue
        update_lxc_container "node-2" "${NODE2_HOST}" "${ct}"
    done
fi

# ==============================================================================
# 3. Update Baseline Native Applications & Run Instance Workload Hook
# ==============================================================================
log_header "STAGE 3: Native Application Updates"

# 3a. AdGuard Home (CT 501 / CT 502)
update_adguard_home() {
    local node_name="$1"
    local node_ip="$2"
    local ct_id="$3"

    if ! is_ct_running "${node_ip}" "${ct_id}"; then
        return 0
    fi

    log "[*] Updating Native App: AdGuard Home (CT ${ct_id} on ${node_name})..."
    if [ "$DRY_RUN" = true ]; then
        agh_ver=$(run_in_ct "${node_ip}" "${ct_id}" "/opt/AdGuardHome/AdGuardHome --version 2>&1 | head -n 1 || echo 'unknown'")
        log "[DRY-RUN] AdGuard Home (CT ${ct_id}) current: ${agh_ver}"
    else
        run_in_ct "${node_ip}" "${ct_id}" "/opt/AdGuardHome/AdGuardHome -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome/data --update 2>/dev/null || true; (systemctl is-active --quiet AdGuardHome || systemctl restart AdGuardHome)"
        new_agh_ver=$(run_in_ct "${node_ip}" "${ct_id}" "/opt/AdGuardHome/AdGuardHome --version 2>&1 | head -n 1 || echo 'unknown'")
        log "[+] AdGuard Home (CT ${ct_id}) active version: ${new_agh_ver}"
    fi
}

if [ "$PROCESS_NODE1" = true ]; then
    update_adguard_home "node-1" "${NODE1_HOST}" "501"
fi

if [ "$PROCESS_NODE2" = true ]; then
    update_adguard_home "node-2" "${NODE2_HOST}" "502"
fi

# 3b. adguardhome-sync (CT 501 on node-1)
if [ "$PROCESS_NODE1" = true ] && is_ct_running "${NODE1_HOST}" "501"; then
    log "[*] Updating Native App: adguardhome-sync (CT 501)..."
    if [ "$DRY_RUN" = true ]; then
        sync_ver=$(run_in_ct "${NODE1_HOST}" "501" "/usr/local/bin/adguardhome-sync --version 2>&1 || echo 'unknown'")
        log "[DRY-RUN] adguardhome-sync current: ${sync_ver}"
    else
        run_in_ct "${NODE1_HOST}" "501" "
            LATEST_TAG=\$(curl -fsSL --connect-timeout 5 https://api.github.com/repos/bakito/adguardhome-sync/releases/latest 2>/dev/null | grep '\"tag_name\":' | sed -E 's/.*\"([^\"]+)\".*/\1/' || true)
            if [ -n \"\$LATEST_TAG\" ]; then
                CURRENT_VER=\$(/usr/local/bin/adguardhome-sync --version 2>&1 | awk '{print \$NF}' || true)
                if [ \"\$CURRENT_VER\" != \"\${LATEST_TAG#v}\" ]; then
                    echo \"[*] Upgrading adguardhome-sync from \$CURRENT_VER to \$LATEST_TAG...\"
                    curl -fsSL -o /tmp/agh-sync.tar.gz \"https://github.com/bakito/adguardhome-sync/releases/download/\${LATEST_TAG}/adguardhome-sync_\${LATEST_TAG#v}_linux_amd64.tar.gz\"
                    tar -xzf /tmp/agh-sync.tar.gz -C /tmp adguardhome-sync
                    install -m 755 /tmp/adguardhome-sync /usr/local/bin/adguardhome-sync
                    rm -f /tmp/agh-sync.tar.gz /tmp/adguardhome-sync
                    systemctl restart adguardhome-sync
                    echo \"[+] adguardhome-sync upgraded to \$LATEST_TAG\"
                else
                    echo \"[+] adguardhome-sync is already at latest version (\$CURRENT_VER)\"
                fi
            else
                echo \"[!] Unable to query latest release for adguardhome-sync\"
            fi
        "
        new_sync_ver=$(run_in_ct "${NODE1_HOST}" "501" "/usr/local/bin/adguardhome-sync --version 2>&1 || echo 'unknown'")
        log "[+] adguardhome-sync status: ${new_sync_ver}"
    fi
fi

# 3c. Cloudflared Tunnel Connector (CT 510 on node-1 & CT 511 on node-2)
update_cloudflared() {
    local node_name="$1"
    local node_ip="$2"
    local ct_id="$3"

    if ! is_ct_running "${node_ip}" "${ct_id}"; then
        return 0
    fi

    log "[*] Updating Native App: Cloudflared Tunnel (CT ${ct_id} on ${node_name})..."
    if [ "$DRY_RUN" = true ]; then
        cf_ver=$(run_in_ct "${node_ip}" "${ct_id}" "cloudflared --version 2>&1 || echo 'unknown'")
        log "[DRY-RUN] Cloudflared (CT ${ct_id}) current: ${cf_ver}"
    else
        run_in_ct "${node_ip}" "${ct_id}" "
            TMP_DEB=\$(mktemp /tmp/cloudflared.XXXXXX.deb)
            if curl -fsSL --retry 3 --connect-timeout 10 -o \"\$TMP_DEB\" \"https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb\"; then
                dpkg -i \"\$TMP_DEB\" >/dev/null 2>&1 || apt-get install -f -y -q >/dev/null 2>&1
                rm -f \"\$TMP_DEB\"
                systemctl restart cloudflared
            else
                rm -f \"\$TMP_DEB\"
                echo '[-] Failed to download cloudflared deb'
            fi
        "
        new_cf_ver=$(run_in_ct "${node_ip}" "${ct_id}" "cloudflared --version 2>&1 || echo 'unknown'")
        log "[+] Cloudflared (CT ${ct_id}) active version: ${new_cf_ver}"
    fi
}

if [ "$PROCESS_NODE1" = true ]; then
    update_cloudflared "node-1" "${NODE1_HOST}" "510"
fi

if [ "$PROCESS_NODE2" = true ]; then
    update_cloudflared "node-2" "${NODE2_HOST}" "511"
fi

# 3d. Antigravity CLI & Remote Control Daemon (CT 900)
if [ "$PROCESS_NODE1" = true ] && is_ct_running "${NODE1_HOST}" "900"; then
    log "[*] Updating Native App: Antigravity CLI & Remote Control Daemon (CT 900)..."
    if [ "$DRY_RUN" = true ]; then
        agy_ver=$(run_in_ct "${NODE1_HOST}" "900" "PATH=\"/root/.local/bin:\$PATH\" agy --version 2>&1 || echo 'unknown'")
        log "[DRY-RUN] Antigravity CLI version: ${agy_ver}"
    else
        run_in_ct "${NODE1_HOST}" "900" "
            export PATH=\"/root/.local/bin:\$PATH\"
            export XDG_RUNTIME_DIR=\"/run/user/0\"
            if command -v agy >/dev/null 2>&1; then
                agy update || true
            fi
            if systemctl --user is-active --quiet agy-remote-control.service 2>/dev/null; then
                systemctl --user restart agy-remote-control.service
                echo '[+] Restarted agy-remote-control.service'
            fi
        "
        new_agy_ver=$(run_in_ct "${NODE1_HOST}" "900" "PATH=\"/root/.local/bin:\$PATH\" agy --version 2>&1 || echo 'unknown'")
        log "[+] Antigravity active version: ${new_agy_ver}"
    fi
fi

# 3e. Execute Instance Workload Hook (if present)
INSTANCE_UPDATE_HOOK="${REPO_ROOT}/scripts/instance/update-instance-workloads.sh"
if [ -f "${INSTANCE_UPDATE_HOOK}" ]; then
    log "[*] Found instance workload update hook at ${INSTANCE_UPDATE_HOOK}. Executing..."
    bash "${INSTANCE_UPDATE_HOOK}" "${TARGET_NODE}" "${DRY_RUN}" || true
fi

# ==============================================================================
# 4. Update Docker Compose Stacks (Dynamic /opt/* Discovery)
# ==============================================================================
log_header "STAGE 4: Docker Compose Stacks (Pull, Update & Prune)"

update_docker_stack() {
    local node_name="$1"
    local node_ip="$2"
    local ct_id="$3"
    local stack_name="$4"
    local stack_dir="$5"

    if ! is_ct_running "${node_ip}" "${ct_id}"; then
        log "[!] CT ${ct_id} (${stack_name}) is not running. Skipping Docker stack update."
        return 0
    fi

    log "[*] Updating Docker Compose Stack: ${stack_name} (CT ${ct_id} on ${node_name})..."

    if [ "$DRY_RUN" = true ]; then
        log "[DRY-RUN] Checking compose stack at ${stack_dir} in CT ${ct_id}..."
        run_in_ct "${node_ip}" "${ct_id}" "
            if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
                echo '[!] Docker compose is not available in CT ${ct_id}. Skipping.'
                exit 0
            fi
            if [ -d '${stack_dir}' ] && { [ -f '${stack_dir}/docker-compose.yml' ] || [ -f '${stack_dir}/docker-compose.yaml' ] || [ -f '${stack_dir}/compose.yml' ] || [ -f '${stack_dir}/compose.yaml' ]; }; then
                cd '${stack_dir}'
                echo '[DRY-RUN] Compose config check:'
                docker compose config --services
            else
                echo '[!] Compose file not found in ${stack_dir}'
            fi
        "
    else
        log "[*] Pulling latest images, rebuilding stack and pruning unused images for ${stack_name}..."
        if run_in_ct "${node_ip}" "${ct_id}" "
            if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
                echo '[!] Docker compose is not available in CT ${ct_id}. Skipping.'
                exit 0
            fi
            if [ -d '${stack_dir}' ]; then
                cd '${stack_dir}'
                echo '[*] Executing docker compose pull...'
                docker compose pull
                echo '[*] Applying updated container definitions...'
                docker compose up -d --remove-orphans
                echo '[*] Pruning unused legacy Docker images...'
                docker image prune -f
                echo '[+] Docker stack ${stack_name} is running latest images:'
                docker compose ps
            else
                echo '[-] Error: ${stack_dir} directory does not exist!'
                exit 1
            fi
        "; then
            log "[+] Docker Compose stack ${stack_name} (CT ${ct_id}) successfully updated."
        else
            log "[!] Warning: Docker Compose stack ${stack_name} (CT ${ct_id}) update encountered non-zero status."
        fi
    fi
}

update_node_docker_stacks() {
    local node_name="$1"
    local node_ip="$2"
    shift 2
    local -a cts=("$@")

    if ! run_on_node "${node_ip}" "true" >/dev/null 2>&1; then
        log "[!] Host ${node_name} (${node_ip}) unreachable. Skipping Docker stack scan."
        return 0
    fi

    log "[*] Dynamically scanning active containers on ${node_name} for Docker Compose stacks in /opt/*..."
    for ct_id in "${cts[@]}"; do
        [ -z "${ct_id}" ] && continue
        if ! is_ct_running "${node_ip}" "${ct_id}"; then
            continue
        fi

        local discovered_stacks
        # shellcheck disable=SC2016
        discovered_stacks=$(run_in_ct "${node_ip}" "${ct_id}" '
            if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
                exit 0
            fi
            for d in /opt/*/; do
                if [ -d "$d" ] && { [ -f "${d}docker-compose.yml" ] || [ -f "${d}docker-compose.yaml" ] || [ -f "${d}compose.yml" ] || [ -f "${d}compose.yaml" ]; }; then
                    basename "$d"
                fi
            done
        ' 2>/dev/null || true)

        if [ -n "${discovered_stacks}" ]; then
            while IFS= read -r stack_name; do
                [ -z "${stack_name}" ] && continue
                update_docker_stack "${node_name}" "${node_ip}" "${ct_id}" "${stack_name}" "/opt/${stack_name}"
            done <<< "${discovered_stacks}"
        fi
    done
}

if [ "$PROCESS_NODE1" = true ]; then
    if [ ${#ACTIVE_NODE1_CTS[@]} -eq 0 ]; then
        mapfile -t ACTIVE_NODE1_CTS < <(get_running_cts "${NODE1_HOST}")
    fi
    update_node_docker_stacks "node-1" "${NODE1_HOST}" "${ACTIVE_NODE1_CTS[@]}"
fi

if [ "$PROCESS_NODE2" = true ]; then
    if [ ${#ACTIVE_NODE2_CTS[@]} -eq 0 ]; then
        mapfile -t ACTIVE_NODE2_CTS < <(get_running_cts "${NODE2_HOST}")
    fi
    update_node_docker_stacks "node-2" "${NODE2_HOST}" "${ACTIVE_NODE2_CTS[@]}"
fi

# ==============================================================================
# Completion Summary
# ==============================================================================
log_header "UPDATE SUMMARY & STATUS"
if [ "$DRY_RUN" = true ]; then
    log "[+] DRY-RUN Simulation completed successfully. All components inspected without error."
else
    log "[+] All scheduled updates for homelab cluster completed successfully."
fi
log "=============================================================================="
