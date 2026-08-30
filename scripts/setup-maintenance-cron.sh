#!/usr/bin/env bash
# ==============================================================================
# Homelab Maintenance Automation & Cron Installation Setup
# ==============================================================================
# Installs and synchronizes:
#   1. Daily update cron job (05:00 AM daily) on proxmox & tuxmox:
#      0 5 * * * /root/homelab-iac/scripts/update-cluster-stack.sh >> /var/log/homelab-updates.log 2>&1
#
#   2. Daily security audit cron job (05:30 AM daily) on proxmox:
#      30 5 * * * /root/homelab-iac/scripts/scan-security.sh --discord --report >> /var/log/homelab-security-audit.log 2>&1
#
#   3. Weekly rolling reboot cron jobs:
#      - proxmox: Sunday 04:00 AM
#        0 4 * * 0 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
#      - tuxmox:  Monday 04:00 AM
#        0 4 * * 1 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
#
#   4. Syncs scripts to /root/homelab-iac/scripts on both nodes with executable permissions.
#   5. Verifies active crontab configuration on both nodes.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Dynamic configuration sourcing
if [ -f "${BASE_DIR}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${BASE_DIR}/homelab-secrets.env"
fi

PROXMOX_HOST="${PROXMOX_HOST:-${PROXMOX_NODE_IP:-10.0.0.10}}"
TUXMOX_HOST="${TUXMOX_HOST:-${TUXMOX_NODE_IP:-10.0.0.20}}"

echo "=============================================================================="
echo "    Homelab Maintenance & Cron Automation Installer                          "
echo "=============================================================================="

# Helper to execute on node
run_on_node() {
    local node_ip="$1"
    local cmd="$2"
    local current_host
    current_host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")

    if [[ "$node_ip" == "${PROXMOX_HOST}" && ("$current_host" == "proxmox" || "$current_host" == "proxmox.local") ]] || \
       [[ "$node_ip" == "${TUXMOX_HOST}" && ("$current_host" == "tuxmox" || "$current_host" == "tuxmox.local") ]]; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 "root@${node_ip}" "${cmd}"
    fi
}

# Helper to sync scripts to target node
sync_scripts_to_node() {
    local node_ip="$1"
    local node_name="$2"
    local current_host
    current_host=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "")

    echo "[*] Synchronizing maintenance scripts to ${node_name} (${node_ip})..."

    if [[ "$node_ip" == "${PROXMOX_HOST}" && ("$current_host" == "proxmox" || "$current_host" == "proxmox.local") ]] || \
       [[ "$node_ip" == "${TUXMOX_HOST}" && ("$current_host" == "tuxmox" || "$current_host" == "tuxmox.local") ]]; then
        mkdir -p /root/homelab-iac/scripts
        cp -a "${SCRIPT_DIR}"/*.sh /root/homelab-iac/scripts/ 2>/dev/null || true
        chmod +x /root/homelab-iac/scripts/*.sh 2>/dev/null || true
        if [ -f "${BASE_DIR}/homelab-secrets.env" ]; then
            cp -a "${BASE_DIR}/homelab-secrets.env" /root/homelab-iac/homelab-secrets.env 2>/dev/null || true
            chmod 600 /root/homelab-iac/homelab-secrets.env 2>/dev/null || true
        fi
        for cfg in .security-exceptions.yaml .checkov.yaml .trivy.yaml .trivyignore; do
            if [ -f "${BASE_DIR}/${cfg}" ]; then
                cp -a "${BASE_DIR}/${cfg}" "/root/homelab-iac/${cfg}" 2>/dev/null || true
            fi
        done
    else
        ssh -o StrictHostKeyChecking=no "root@${node_ip}" "mkdir -p /root/homelab-iac/scripts"
        scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}"/*.sh "root@${node_ip}:/root/homelab-iac/scripts/"
        ssh -o StrictHostKeyChecking=no "root@${node_ip}" "chmod +x /root/homelab-iac/scripts/*.sh"
        if [ -f "${BASE_DIR}/homelab-secrets.env" ]; then
            scp -o StrictHostKeyChecking=no "${BASE_DIR}/homelab-secrets.env" "root@${node_ip}:/root/homelab-iac/homelab-secrets.env" 2>/dev/null || true
            ssh -o StrictHostKeyChecking=no "root@${node_ip}" "chmod 600 /root/homelab-iac/homelab-secrets.env" 2>/dev/null || true
        fi
        for cfg in .security-exceptions.yaml .checkov.yaml .trivy.yaml .trivyignore; do
            if [ -f "${BASE_DIR}/${cfg}" ]; then
                scp -o StrictHostKeyChecking=no "${BASE_DIR}/${cfg}" "root@${node_ip}:/root/homelab-iac/${cfg}" 2>/dev/null || true
            fi
        done
    fi
    echo "[+] Scripts and configurations synchronized to ${node_name}:/root/homelab-iac"
}

# ------------------------------------------------------------------------------
# 1. Connectivity Check
# ------------------------------------------------------------------------------
echo "[*] Step 1/4: Checking cluster host reachability..."
if ! run_on_node "${PROXMOX_HOST}" "true"; then
    echo "[-] Error: Cannot reach proxmox host at ${PROXMOX_HOST}" >&2
    exit 1
fi
echo "[+] Proxmox host (${PROXMOX_HOST}) is reachable."

if ! run_on_node "${TUXMOX_HOST}" "true"; then
    echo "[-] Error: Cannot reach tuxmox host at ${TUXMOX_HOST}" >&2
    exit 1
fi
echo "[+] Tuxmox host (${TUXMOX_HOST}) is reachable."

# ------------------------------------------------------------------------------
# 2. Synchronize Scripts
# ------------------------------------------------------------------------------
echo "[*] Step 2/4: Deploying maintenance scripts to cluster nodes..."
sync_scripts_to_node "${PROXMOX_HOST}" "proxmox"
sync_scripts_to_node "${TUXMOX_HOST}" "tuxmox"

# ------------------------------------------------------------------------------
# 3. Configure Crontab on Nodes
# ------------------------------------------------------------------------------
echo "[*] Step 3/4: Installing cron schedules on proxmox and tuxmox..."

# Proxmox Crontab Definition
# Daily 05:00 AM update + Daily 05:30 AM security audit + Sunday 04:00 AM rolling reboot
run_on_node "${PROXMOX_HOST}" "bash -s" <<'CRON_PROXMOX_EOF'
# Read current crontab excluding previous homelab maintenance entries
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v 'update-cluster-stack\.sh' | grep -v 'scan-security\.sh' | grep -v 'scheduled-reboot\.sh' | grep -v '# Homelab Maintenance' || true)

# Write updated crontab
cat <<EOF | crontab -
${EXISTING_CRON}
# Homelab Maintenance Automation (Node: proxmox)
0 5 * * * /root/homelab-iac/scripts/update-cluster-stack.sh >> /var/log/homelab-updates.log 2>&1
30 5 * * * /root/homelab-iac/scripts/scan-security.sh --discord --report >> /var/log/homelab-security-audit.log 2>&1
0 4 * * 0 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
EOF
CRON_PROXMOX_EOF
echo "[+] Crontab installed on proxmox (${PROXMOX_HOST})."

# Tuxmox Crontab Definition
# Daily 05:00 AM update + Monday 04:00 AM rolling reboot
run_on_node "${TUXMOX_HOST}" "bash -s" <<'CRON_TUXMOX_EOF'
# Read current crontab excluding previous homelab maintenance entries
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v 'update-cluster-stack\.sh' | grep -v 'scheduled-reboot\.sh' | grep -v '# Homelab Maintenance' || true)

# Write updated crontab
cat <<EOF | crontab -
${EXISTING_CRON}
# Homelab Maintenance Automation (Node: tuxmox)
0 5 * * * /root/homelab-iac/scripts/update-cluster-stack.sh >> /var/log/homelab-updates.log 2>&1
0 4 * * 1 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
EOF
CRON_TUXMOX_EOF
echo "[+] Crontab installed on tuxmox (${TUXMOX_HOST})."

# ------------------------------------------------------------------------------
# 4. Verification & Diagnostics
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "    Verification: Active Crontab Schedules                                    "
echo "=============================================================================="

echo "[*] Node 1 (proxmox - ${PROXMOX_HOST}) crontab -l:"
run_on_node "${PROXMOX_HOST}" "crontab -l"
echo ""

echo "[*] Node 2 (tuxmox - ${TUXMOX_HOST}) crontab -l:"
run_on_node "${TUXMOX_HOST}" "crontab -l"
echo ""

echo "=============================================================================="
echo "[+] Homelab maintenance cron jobs successfully installed and verified!       "
echo "=============================================================================="
