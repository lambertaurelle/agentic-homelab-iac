#!/usr/bin/env bash
# ==============================================================================
# Proxmox LXC Disaster Recovery & Interactive Restoration Tool
# ==============================================================================
# Phase 2: Disaster Recovery & Backup Automation
#
# Features:
#   - Discovers available backups on 'syno-backup' (/mnt/pve/syno-backup/dump)
#   - List mode: '--list' displays available backups, sizes, and timestamps
#   - Single restore: './restore-all-lxc.sh <CTID>' (e.g. 101, 510)
#   - Bulk restore: './restore-all-lxc.sh --all' (restores all available backups)
#   - Safety checks: Overwrite confirmation and safe stopping of running CTs
#   - Post-restore automated container startup and health check
#   - Multi-node support: Routes commands to appropriate node (proxmox/tuxmox)
# ==============================================================================
set -euo pipefail

# Dynamic configuration sourcing
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

PROXMOX_HOST="${PROXMOX_HOST:-${PROXMOX_NODE_IP:-10.0.0.10}}"
TUXMOX_HOST="${TUXMOX_HOST:-${TUXMOX_NODE_IP:-10.0.0.20}}"
BACKUP_STORAGE="${BACKUP_STORAGE:-syno-backup}"
BACKUP_DIR="${BACKUP_DIR:-/mnt/pve/syno-backup/dump}"
DEFAULT_ROOTFS_STORAGE="${DEFAULT_ROOTFS_STORAGE:-local-lvm}"

# Default node assignments for homelab containers
get_default_node() {
    local ctid="$1"
    case "${ctid}" in
        101|102|301|401|502|511|901)
            echo "tuxmox"
            ;;
        201|501|510|601|900|*)
            echo "proxmox"
            ;;
    esac
}

get_known_name() {
    local ctid="$1"
    case "${ctid}" in
        101) echo "plex" ;;
        102) echo "audiobookshelf" ;;
        201) echo "seedbox" ;;
        301) echo "immich" ;;
        401) echo "teamspeak" ;;
        501) echo "adguard-primary" ;;
        502) echo "adguard-secondary" ;;
        510) echo "cloudflared-primary" ;;
        511) echo "cloudflared-secondary" ;;
        601) echo "monitoring" ;;
        900) echo "mgmt-devops" ;;
        901) echo "workstation" ;;
        *)   echo "unknown" ;;
    esac
}

# Helper to run a command on a specific node
run_on_node() {
    local node="$1"
    local cmd="$2"
    local target_host="${PROXMOX_HOST}"
    if [ "${node}" = "tuxmox" ] || [ "${node}" = "${TUXMOX_HOST}" ]; then
        target_host="${TUXMOX_HOST}"
    fi

    if command -v pct >/dev/null 2>&1 && [ "$(hostname)" = "${node}" ]; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no "root@${target_host}" "${cmd}"
    fi
}

# Helper to run a command on cluster master
run_on_master() {
    local cmd="$1"
    if command -v pvesm >/dev/null 2>&1; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no "root@${PROXMOX_HOST}" "${cmd}"
    fi
}

# Get list of backup files from NAS
get_backup_files() {
    run_on_master "ls -1 ${BACKUP_DIR}/vzdump-lxc-*.tar.* 2>/dev/null || true"
}

# Print help message
show_help() {
    cat << 'HLP'
Usage: restore-all-lxc.sh [OPTIONS] [CTID]

Options:
  -l, --list             List all available LXC container backups on syno-backup
  -a, --all              Restore all containers with available backups
  -s, --storage <pool>   Target rootfs storage pool (default: local-lvm)
  -n, --node <node>      Target Proxmox node (proxmox | tuxmox; auto-detected if omitted)
  -f, --file <filename>  Specific backup archive filename or path to restore
      --no-start         Do not start container after restoration
  -y, --yes, --force     Non-interactive mode (auto-confirm overwrite/restore)
  -h, --help             Display this help message

Examples:
  ./restore-all-lxc.sh --list
  ./restore-all-lxc.sh 510
  ./restore-all-lxc.sh 101 --storage local-lvm --yes
  ./restore-all-lxc.sh --all -y
HLP
}

# ------------------------------------------------------------------------------
# List Backups
# ------------------------------------------------------------------------------
list_backups() {
    echo "========================================================================================================="
    echo "    Available LXC Container Backups on '${BACKUP_STORAGE}' (${BACKUP_DIR})                               "
    echo "========================================================================================================="

    local raw_list
    raw_list=$(run_on_master "ls -la --time-style='+%Y-%m-%d %H:%M:%S' ${BACKUP_DIR}/vzdump-lxc-*.tar.* 2>/dev/null || true")

    if [ -z "${raw_list}" ]; then
        echo "[-] No LXC backups found in ${BACKUP_DIR} on storage '${BACKUP_STORAGE}'."
        return 0
    fi

    printf "%-6s | %-22s | %-19s | %-10s | %s\n" "CTID" "CONTAINER NAME" "BACKUP TIMESTAMP" "SIZE" "ARCHIVE FILENAME"
    printf "%s\n" "-------+------------------------+---------------------+------------+--------------------------------------"

    while IFS= read -r line; do
        [ -z "${line}" ] && continue
        # shellcheck disable=SC2034
        local size date time filepath filename ctid ts_formatted ct_name
        size=$(echo "${line}" | awk '{print $5}')
        # shellcheck disable=SC2034
        date=$(echo "${line}" | awk '{print $6}')
        # shellcheck disable=SC2034
        time=$(echo "${line}" | awk '{print $7}')
        filepath=$(echo "${line}" | awk '{print $8}')
        filename=$(basename "${filepath}")

        # Human-readable size
        local hr_size
        if [ "${size}" -ge 1073741824 ]; then
            hr_size=$(awk -v s="${size}" 'BEGIN {printf "%.2f GB", s/1073741824}')
        elif [ "${size}" -ge 1048576 ]; then
            hr_size=$(awk -v s="${size}" 'BEGIN {printf "%.1f MB", s/1048576}')
        elif [ "${size}" -ge 1024 ]; then
            hr_size=$(awk -v s="${size}" 'BEGIN {printf "%.0f KB", s/1024}')
        else
            hr_size="${size} B"
        fi

        # Parse CTID: vzdump-lxc-<CTID>-<timestamp>
        ctid=$(echo "${filename}" | sed -E 's/^vzdump-lxc-([0-9]+)-.*/\1/')
        # Parse timestamp from filename: YYYY_MM_DD-HH_MM_SS
        local raw_ts
        raw_ts=$(echo "${filename}" | sed -E 's/^vzdump-lxc-[0-9]+-([0-9]{4}_[0-9]{2}_[0-9]{2}-[0-9]{2}_[0-9]{2}_[0-9]{2})\..*/\1/')
        ts_formatted=$(echo "${raw_ts}" | sed -E 's/([0-9]{4})_([0-9]{2})_([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2})/\1-\2-\3 \4:\5:\6/')

        # Try to extract CT name from corresponding log file or known table
        local logfile="${BACKUP_DIR}/vzdump-lxc-${ctid}-${raw_ts}.log"
        ct_name=$(run_on_master "grep -m 1 'CT Name:' ${logfile} 2>/dev/null | sed -E 's/.*CT Name:\s*//' || true")
        if [ -z "${ct_name}" ]; then
            ct_name=$(get_known_name "${ctid}")
        fi

        printf "%-6s | %-22s | %-19s | %-10s | %s\n" "${ctid}" "${ct_name}" "${ts_formatted}" "${hr_size}" "${filename}"
    done <<< "${raw_list}"

    echo "========================================================================================================="
}

# ------------------------------------------------------------------------------
# Restore Single Container
# ------------------------------------------------------------------------------
restore_container() {
    local ctid="$1"
    local target_storage="$2"
    local explicit_node="$3"
    local specific_file="$4"
    local auto_start="$5"
    local auto_confirm="$6"

    echo "------------------------------------------------------------------------------"
    echo "[*] Preparing restoration for CT ${ctid}..."

    # 1. Locate backup archive
    local archive_path=""
    if [ -n "${specific_file}" ]; then
        if [[ "${specific_file}" = /* ]]; then
            archive_path="${specific_file}"
        else
            archive_path="${BACKUP_DIR}/${specific_file}"
        fi
    else
        # Find latest backup for this CTID
        local latest_file
        latest_file=$(run_on_master "ls -1t ${BACKUP_DIR}/vzdump-lxc-${ctid}-*.tar.* 2>/dev/null | head -n 1 || true")
        if [ -z "${latest_file}" ]; then
            echo "[-] Error: No backup archive found for CT ${ctid} in ${BACKUP_DIR}." >&2
            return 1
        fi
        archive_path="${latest_file}"
    fi

    local archive_filename
    archive_filename=$(basename "${archive_path}")
    echo "[+] Selected backup archive: ${archive_filename}"

    # 2. Determine target node
    local target_node="${explicit_node}"
    if [ -z "${target_node}" ]; then
        # Check if container currently exists in cluster
        local cluster_node
        cluster_node=$(run_on_master "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" | \
            grep -o "{\"cpu\"[^}]*\"vmid\":${ctid}[^}]*}" | grep -o '\"node\":\"[^\"]*\"' | cut -d'"' -f4 || true)
        if [ -n "${cluster_node}" ]; then
            target_node="${cluster_node}"
            echo "[+] Detected existing CT ${ctid} on cluster node: ${target_node}"
        else
            target_node=$(get_default_node "${ctid}")
            echo "[+] Default node assignment for CT ${ctid}: ${target_node}"
        fi
    fi

    # 3. Check existing container status on target node
    local ct_exists="no"
    local ct_running="no"
    local ct_name
    ct_name=$(get_known_name "${ctid}")

    local check_status
    check_status=$(run_on_node "${target_node}" "pct status ${ctid} 2>&1 || true")
    if [[ "${check_status}" == *"status:"* ]]; then
        ct_exists="yes"
        if [[ "${check_status}" == *"status: running"* ]]; then
            ct_running="yes"
        fi
    fi

    # 4. Confirmation check
    if [ "${auto_confirm}" != "yes" ]; then
        if [ "${ct_exists}" = "yes" ]; then
            echo "[!] WARNING: Container ${ctid} (${ct_name}) already exists on node '${target_node}' (running: ${ct_running})."
            echo "    Restoration will overwrite existing rootfs on storage '${target_storage}'."
            read -r -p "    Are you sure you want to restore CT ${ctid}? [y/N]: " answer
            if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
                echo "[-] Restoration of CT ${ctid} cancelled by user."
                return 0
            fi
        else
            read -r -p "[?] Container ${ctid} will be restored on node '${target_node}' (storage: ${target_storage}). Proceed? [y/N]: " answer
            if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
                echo "[-] Restoration of CT ${ctid} cancelled by user."
                return 0
            fi
        fi
    fi

    # 5. Stop existing container if running
    if [ "${ct_running}" = "yes" ]; then
        echo "[*] Stopping running container ${ctid} on ${target_node}..."
        run_on_node "${target_node}" "pct stop ${ctid} --timeout 30 || pct stop ${ctid} -force 1"
        sleep 2
    fi

    # 6. Execute pct restore
    echo "[*] Restoring CT ${ctid} from archive '${archive_filename}' onto node '${target_node}' (storage: ${target_storage})..."
    local restore_cmd="pct restore ${ctid} ${archive_path} --storage ${target_storage} --force 1"

    if run_on_node "${target_node}" "${restore_cmd}"; then
        echo "[+] Successfully restored container ${ctid} on node '${target_node}'."
    else
        echo "[-] Error: Restoration failed for CT ${ctid}." >&2
        return 1
    fi

    # 7. Start container if requested
    if [ "${auto_start}" = "yes" ]; then
        echo "[*] Starting restored container ${ctid} on ${target_node}..."
        run_on_node "${target_node}" "pct start ${ctid}"
        sleep 3
        local final_status
        final_status=$(run_on_node "${target_node}" "pct status ${ctid} 2>/dev/null || true")
        echo "[+] Container ${ctid} status on ${target_node}: ${final_status}"
    fi

    echo "[+] Restoration of CT ${ctid} completed successfully."
}

# ------------------------------------------------------------------------------
# Restore All Containers
# ------------------------------------------------------------------------------
restore_all() {
    local target_storage="$1"
    local explicit_node="$2"
    local auto_start="$3"
    local auto_confirm="$4"

    echo "=============================================================================="
    echo "    Bulk Disaster Recovery Restoration: All Available Containers             "
    echo "=============================================================================="

    local backup_files
    backup_files=$(run_on_master "ls -1 ${BACKUP_DIR}/vzdump-lxc-*.tar.* 2>/dev/null || true")

    if [ -z "${backup_files}" ]; then
        echo "[-] Error: No backup archives found in ${BACKUP_DIR}." >&2
        return 1
    fi

    # Discover unique CTIDs
    local ctids
    ctids=$(echo "${backup_files}" | sed -E 's/.*vzdump-lxc-([0-9]+)-.*/\1/' | sort -u -n)
    local ctid_list
    ctid_list=$(echo "${ctids}" | tr '\n' ' ')

    echo "[*] Found backups for container IDs: ${ctid_list}"

    if [ "${auto_confirm}" != "yes" ]; then
        echo "[!] WARNING: You are about to restore ALL of the following containers:"
        echo "    Containers: ${ctid_list}"
        echo "    Target Storage: ${target_storage}"
        read -r -p "    Are you sure you want to proceed with full cluster restoration? [y/N]: " answer
        if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
            echo "[-] Bulk restoration cancelled by user."
            return 0
        fi
    fi

    local success_count=0
    local fail_count=0

    for ctid in ${ctids}; do
        if restore_container "${ctid}" "${target_storage}" "${explicit_node}" "" "${auto_start}" "yes"; then
            ((success_count++))
        else
            ((fail_count++))
            echo "[-] Restoration failed for CT ${ctid}, proceeding with remaining containers..."
        fi
    done

    echo "=============================================================================="
    echo "    Bulk Restoration Finished: ${success_count} succeeded, ${fail_count} failed."
    echo "=============================================================================="
}

# ------------------------------------------------------------------------------
# Main Entrypoint & Argument Parsing
# ------------------------------------------------------------------------------
main() {
    local mode="single"
    local ctid=""
    local target_storage="${DEFAULT_ROOTFS_STORAGE}"
    local explicit_node=""
    local specific_file=""
    local auto_start="yes"
    local auto_confirm="no"

    if [ $# -eq 0 ]; then
        show_help
        exit 0
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            -l|--list)
                mode="list"
                shift
                ;;
            -a|--all)
                mode="all"
                shift
                ;;
            -s|--storage)
                target_storage="$2"
                shift 2
                ;;
            -n|--node)
                explicit_node="$2"
                shift 2
                ;;
            -f|--file)
                specific_file="$2"
                shift 2
                ;;
            --no-start)
                auto_start="no"
                shift
                ;;
            -y|--yes|--force)
                auto_confirm="yes"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            [0-9]*)
                ctid="$1"
                shift
                ;;
            *)
                echo "[-] Unknown option: $1" >&2
                show_help
                exit 1
                ;;
        esac
    done

    case "${mode}" in
        list)
            list_backups
            ;;
        all)
            restore_all "${target_storage}" "${explicit_node}" "${auto_start}" "${auto_confirm}"
            ;;
        single)
            if [ -z "${ctid}" ]; then
                echo "[-] Error: Please specify a Container ID to restore or use '--list' / '--all'." >&2
                echo ""
                show_help
                exit 1
            fi
            restore_container "${ctid}" "${target_storage}" "${explicit_node}" "${specific_file}" "${auto_start}" "${auto_confirm}"
            ;;
    esac
}

main "$@"
