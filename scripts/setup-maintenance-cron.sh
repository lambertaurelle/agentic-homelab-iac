#!/usr/bin/env bash
# ==============================================================================
# Homelab Maintenance Automation & Cron Installation Setup
# ==============================================================================
# Installs and synchronizes:
#   1. Daily update cron job (05:00 AM daily) on node-1 & node-2:
#      0 5 * * * /root/homelab-iac/scripts/update-cluster-stack.sh >> /var/log/homelab-updates.log 2>&1
#
#   2. Daily security audit cron job (05:30 AM daily) on node-1:
#      30 5 * * * /root/homelab-iac/scripts/scan-security.sh --discord --report >> /var/log/homelab-security-audit.log 2>&1
#
#   3. Weekly rolling reboot cron jobs:
#      - node-1: Sunday 04:00 AM
#        0 4 * * 0 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
#      - node-2: Monday 04:00 AM
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

NODE1_IP="${NODE1_IP:-10.0.0.10}"
NODE2_IP="${NODE2_IP:-10.0.0.20}"

echo "=============================================================================="
echo "    Homelab Maintenance & Cron Automation Installer                          "
echo "=============================================================================="

# Helper to execute on node
run_on_node() {
    local node_ip="$1"
    local cmd="$2"

    if ip addr show 2>/dev/null | grep -q "${node_ip}" || [[ "$node_ip" == "localhost" ]] || [[ "$node_ip" == "127.0.0.1" ]]; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=10 "root@${node_ip}" "${cmd}"
    fi
}

# Helper to sync scripts to target node
sync_scripts_to_node() {
    local node_ip="$1"
    local node_name="$2"

    echo "[*] Synchronizing maintenance scripts to ${node_name} (${node_ip})..."

    if ip addr show 2>/dev/null | grep -q "${node_ip}" || [[ "$node_ip" == "localhost" ]] || [[ "$node_ip" == "127.0.0.1" ]]; then
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
if ! run_on_node "${NODE1_IP}" "true"; then
    echo "[-] Error: Cannot reach node-1 host at ${NODE1_IP}" >&2
    exit 1
fi
echo "[+] Node 1 (${NODE1_IP}) is reachable."

if ! run_on_node "${NODE2_IP}" "true"; then
    echo "[-] Error: Cannot reach node-2 host at ${NODE2_IP}" >&2
    exit 1
fi
echo "[+] Node 2 (${NODE2_IP}) is reachable."

# ------------------------------------------------------------------------------
# 2. Synchronize Scripts
# ------------------------------------------------------------------------------
echo "[*] Step 2/4: Deploying maintenance scripts to cluster nodes..."
sync_scripts_to_node "${NODE1_IP}" "node-1"
sync_scripts_to_node "${NODE2_IP}" "node-2"

# ------------------------------------------------------------------------------
# 3. Configure Crontab on Nodes
# ------------------------------------------------------------------------------
echo "[*] Step 3/4: Installing cron schedules on node-1 and node-2..."

# Node 1 Crontab Definition
# Daily 05:00 AM update + Daily 05:30 AM security audit + Sunday 04:00 AM rolling reboot
run_on_node "${NODE1_IP}" "bash -s" <<'CRON_NODE1_EOF'
# Read current crontab excluding previous homelab maintenance entries
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v 'update-cluster-stack\.sh' | grep -v 'scan-security\.sh' | grep -v 'scheduled-reboot\.sh' | grep -v '# Homelab Maintenance' || true)

# Write updated crontab
cat <<EOF | crontab -
${EXISTING_CRON}
# Homelab Maintenance Automation (Node: node-1)
0 5 * * * /root/homelab-iac/scripts/update-cluster-stack.sh >> /var/log/homelab-updates.log 2>&1
30 5 * * * /root/homelab-iac/scripts/scan-security.sh --discord --report >> /var/log/homelab-security-audit.log 2>&1
0 4 * * 0 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
EOF
CRON_NODE1_EOF
echo "[+] Crontab installed on node-1 (${NODE1_IP})."

# Node 2 Crontab Definition
# Daily 05:00 AM update + Monday 04:00 AM rolling reboot
run_on_node "${NODE2_IP}" "bash -s" <<'CRON_NODE2_EOF'
# Read current crontab excluding previous homelab maintenance entries
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v 'update-cluster-stack\.sh' | grep -v 'scheduled-reboot\.sh' | grep -v '# Homelab Maintenance' || true)

# Write updated crontab
cat <<EOF | crontab -
${EXISTING_CRON}
# Homelab Maintenance Automation (Node: node-2)
0 5 * * * /root/homelab-iac/scripts/update-cluster-stack.sh >> /var/log/homelab-updates.log 2>&1
0 4 * * 1 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
EOF
CRON_NODE2_EOF
echo "[+] Crontab installed on node-2 (${NODE2_IP})."

# ------------------------------------------------------------------------------
# 4. Verification & Diagnostics
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "    Verification: Active Crontab Schedules                                    "
echo "=============================================================================="

echo "[*] Node 1 (node-1 - ${NODE1_IP}) crontab -l:"
run_on_node "${NODE1_IP}" "crontab -l"
echo ""

echo "[*] Node 2 (node-2 - ${NODE2_IP}) crontab -l:"
run_on_node "${NODE2_IP}" "crontab -l"
echo ""

echo "=============================================================================="
echo "[+] Homelab maintenance cron jobs successfully installed and verified!       "
echo "=============================================================================="
