#!/usr/bin/env bash
# ==============================================================================
# Homelab Maintenance Automation & Cron Installation Setup
# ==============================================================================
# Installs and synchronizes:
#   1. Daily staggered update cron jobs:
#      - node-1: 04:30 AM daily (with flock mutex)
#        30 4 * * * /usr/bin/flock -n /var/run/homelab-updates.lock /root/homelab-iac/scripts/update-cluster-stack.sh --node node-1 >> /var/log/homelab-updates.log 2>&1
#      - node-2: 04:45 AM daily (with flock mutex)
#        45 4 * * * /usr/bin/flock -n /var/run/homelab-updates.lock /root/homelab-iac/scripts/update-cluster-stack.sh --node node-2 >> /var/log/homelab-updates.log 2>&1
#
#   2. Daily security audit cron job (05:45 AM daily) on node-1:
#      45 5 * * * if pct status 900 2>/dev/null | grep -q 'running'; then pct exec 900 -- /root/homelab-iac/scripts/scan-security.sh --discord --report; else /root/homelab-iac/scripts/scan-security.sh --discord --report; fi >> /var/log/homelab-security-audit.log 2>&1
#
#   3. Weekly rolling reboot cron jobs (05:15 AM):
#      - node-1: Sunday 05:15 AM
#        15 5 * * 0 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
#      - node-2: Monday 05:15 AM
#        15 5 * * 1 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
#
#   4. Daily Morning SRE Proactive Health Check (06:00 AM daily) on CT 900:
#      0 6 * * * /root/homelab-iac/scripts/daily-sre-check.sh >> /var/log/daily-sre-check.log 2>&1
#
#   5. Logrotate (/etc/logrotate.d/homelab-maintenance) and Journald size limits (100M).
#   6. Syncs scripts (including scripts/instance/) to /root/homelab-iac/scripts on both nodes.
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
        mkdir -p /root/homelab-iac/scripts/lib
        cp -a "${SCRIPT_DIR}"/*.sh /root/homelab-iac/scripts/ 2>/dev/null || true
        cp -a "${SCRIPT_DIR}/lib"/* /root/homelab-iac/scripts/lib/ 2>/dev/null || true
        chmod +x /root/homelab-iac/scripts/*.sh 2>/dev/null || true

        # Synchronize private instance scripts if present
        if [ -d "${SCRIPT_DIR}/instance" ]; then
            mkdir -p /root/homelab-iac/scripts/instance
            cp -a "${SCRIPT_DIR}/instance"/* /root/homelab-iac/scripts/instance/ 2>/dev/null || true
            chmod +x /root/homelab-iac/scripts/instance/*.sh 2>/dev/null || true
        fi

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
        ssh -o StrictHostKeyChecking=no "root@${node_ip}" "mkdir -p /root/homelab-iac/scripts/lib"
        scp -o StrictHostKeyChecking=no "${SCRIPT_DIR}"/*.sh "root@${node_ip}:/root/homelab-iac/scripts/"
        scp -r -o StrictHostKeyChecking=no "${SCRIPT_DIR}/lib"/* "root@${node_ip}:/root/homelab-iac/scripts/lib/" 2>/dev/null || true
        ssh -o StrictHostKeyChecking=no "root@${node_ip}" "chmod +x /root/homelab-iac/scripts/*.sh"

        # Synchronize private instance scripts if present
        if [ -d "${SCRIPT_DIR}/instance" ]; then
            ssh -o StrictHostKeyChecking=no "root@${node_ip}" "mkdir -p /root/homelab-iac/scripts/instance"
            scp -r -o StrictHostKeyChecking=no "${SCRIPT_DIR}/instance"/* "root@${node_ip}:/root/homelab-iac/scripts/instance/" 2>/dev/null || true
            ssh -o StrictHostKeyChecking=no "root@${node_ip}" "chmod +x /root/homelab-iac/scripts/instance/*.sh 2>/dev/null || true"
        fi

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
echo "[*] Step 1/6: Checking cluster host reachability..."
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
echo "[*] Step 2/6: Deploying maintenance scripts to cluster nodes..."
sync_scripts_to_node "${NODE1_IP}" "node-1"
sync_scripts_to_node "${NODE2_IP}" "node-2"

# ------------------------------------------------------------------------------
# 3. Configure Crontab on Nodes
# ------------------------------------------------------------------------------
echo "[*] Step 3/6: Installing cron schedules on node-1 and node-2..."

# Node 1 Crontab Definition
# Daily 04:30 AM update + Daily 05:45 AM security audit + Sunday 05:15 AM rolling reboot
run_on_node "${NODE1_IP}" "bash -s" <<'CRON_NODE1_EOF'
# Read current crontab excluding previous homelab maintenance entries
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v 'update-cluster-stack\.sh' | grep -v 'scan-security\.sh' | grep -v 'scheduled-reboot\.sh' | grep -v '# Homelab Maintenance' || true)

# Write updated crontab
cat <<EOF | crontab -
${EXISTING_CRON}
# Homelab Maintenance Automation (Node: node-1)
30 4 * * * /usr/bin/flock -n /var/run/homelab-updates.lock /root/homelab-iac/scripts/update-cluster-stack.sh --node node-1 >> /var/log/homelab-updates.log 2>&1
15 5 * * 0 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
45 5 * * * if pct status 900 2>/dev/null | grep -q 'running'; then pct exec 900 -- /root/homelab-iac/scripts/scan-security.sh --discord --report; else /root/homelab-iac/scripts/scan-security.sh --discord --report; fi >> /var/log/homelab-security-audit.log 2>&1
EOF
CRON_NODE1_EOF
echo "[+] Crontab installed on node-1 (${NODE1_IP})."

# Node 2 Crontab Definition
# Daily 04:45 AM update + Monday 05:15 AM rolling reboot
run_on_node "${NODE2_IP}" "bash -s" <<'CRON_NODE2_EOF'
# Read current crontab excluding previous homelab maintenance entries
EXISTING_CRON=$(crontab -l 2>/dev/null | grep -v 'update-cluster-stack\.sh' | grep -v 'scheduled-reboot\.sh' | grep -v '# Homelab Maintenance' || true)

# Write updated crontab
cat <<EOF | crontab -
${EXISTING_CRON}
# Homelab Maintenance Automation (Node: node-2)
45 4 * * * /usr/bin/flock -n /var/run/homelab-updates.lock /root/homelab-iac/scripts/update-cluster-stack.sh --node node-2 >> /var/log/homelab-updates.log 2>&1
15 5 * * 1 /root/homelab-iac/scripts/scheduled-reboot.sh >> /var/log/homelab-reboot.log 2>&1
EOF
CRON_NODE2_EOF
echo "[+] Crontab installed on node-2 (${NODE2_IP})."

# Local Crontab Configuration for CT 900 (Morning SRE Proactive Agent at 06:00 AM)
if command -v crontab >/dev/null 2>&1 && [ -f "${SCRIPT_DIR}/daily-sre-check.sh" ]; then
    EXISTING_CT_CRON=$(crontab -l 2>/dev/null | grep -v 'daily-sre-check\.sh' || true)
    cat <<EOF | crontab -
${EXISTING_CT_CRON}
# Homelab Daily SRE Proactive Health Check (06:00 AM)
0 6 * * * /root/homelab-iac/scripts/daily-sre-check.sh >> /var/log/daily-sre-check.log 2>&1
EOF
    echo "[+] Morning SRE check cron (06:00 AM) configured in local crontab."
fi

# ------------------------------------------------------------------------------
# 4. Offsite Cloud Backup Schedule Setup
# ------------------------------------------------------------------------------
echo "[*] Step 4/6: Configuring offsite cloud backup schedule (03:45 AM)..."
if [ -f "${SCRIPT_DIR}/setup-offsite-backup-schedule.sh" ]; then
    bash "${SCRIPT_DIR}/setup-offsite-backup-schedule.sh" || echo "[-] Notice: Offsite backup schedule setup skipped or container not ready yet."
fi

# ------------------------------------------------------------------------------
# 5. Configure Logrotate & Journald Limits on Nodes
# ------------------------------------------------------------------------------
echo "[*] Step 5/6: Installing logrotate and journald configurations on cluster nodes..."

LOGROTATE_CONF='cat << '\''LOGROTATE_EOF'\'' > /etc/logrotate.d/homelab-maintenance
/var/log/homelab-updates.log
/var/log/homelab-security-audit.log
/var/log/homelab-reboot.log
/var/log/homelab-offsite-backup.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
}
LOGROTATE_EOF
chmod 644 /etc/logrotate.d/homelab-maintenance'

JOURNALD_CONF='mkdir -p /etc/systemd/journald.conf.d
cat << '\''JOURNALD_EOF'\'' > /etc/systemd/journald.conf.d/homelab-size.conf
[Journal]
SystemMaxUse=100M
SystemKeepFree=500M
MaxRetentionSec=14day
SystemMaxFileSize=25M
JOURNALD_EOF
systemctl restart systemd-journald 2>/dev/null || true
journalctl --vacuum-size=100M --vacuum-time=14d 2>/dev/null || true'

run_on_node "${NODE1_IP}" "${LOGROTATE_CONF}"
run_on_node "${NODE2_IP}" "${LOGROTATE_CONF}"
run_on_node "${NODE1_IP}" "${JOURNALD_CONF}"
run_on_node "${NODE2_IP}" "${JOURNALD_CONF}"

# Also configure locally on management container if running inside CT 900
if [ -d /etc/systemd ]; then
    mkdir -p /etc/systemd/journald.conf.d
    cat << 'JOURNALD_EOF' > /etc/systemd/journald.conf.d/homelab-size.conf
[Journal]
SystemMaxUse=100M
SystemKeepFree=500M
MaxRetentionSec=14day
SystemMaxFileSize=25M
JOURNALD_EOF
fi
echo "[+] Logrotate & journald size limits deployed on cluster nodes."

# ------------------------------------------------------------------------------
# 6. Verification & Diagnostics
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
