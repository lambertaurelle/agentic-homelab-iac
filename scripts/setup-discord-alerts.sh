#!/usr/bin/env bash
# ==============================================================================
# Proxmox VE Native Discord Webhook Alerting Setup
# ==============================================================================
# Configures Proxmox VE Notification Engine (Datacenter -> Notifications)
# to dispatch VZDump backup failures, package updates, and cluster alerts
# directly to your Discord channel via Webhook.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

NODE1_IP="${NODE1_IP:-10.0.0.10}"
DISCORD_WEBHOOK_URL="${DISCORD_MONITORING_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}"

echo "=============================================================================="
echo "    Proxmox VE Discord Webhook Notification Setup                             "
echo "=============================================================================="

if [ -z "${DISCORD_WEBHOOK_URL}" ]; then
    echo "[!] Warning: DISCORD_MONITORING_WEBHOOK_URL (or DISCORD_WEBHOOK_URL) is not set in homelab-secrets.env."
    echo "    Please set DISCORD_MONITORING_WEBHOOK_URL in homelab-secrets.env and re-run this script."
    exit 0
fi

echo "[*] Testing Discord Webhook connectivity..."
TEST_PAYLOAD='{"content": "🟢 **[Homelab Proxmox VE]** Discord Alert Notification Engine initialized successfully!"}'
if ! curl -sfSL -X POST -H "Content-Type: application/json" -d "${TEST_PAYLOAD}" "${DISCORD_WEBHOOK_URL}" >/dev/null; then
    echo "[-] Error: Failed to send test notification to Discord Webhook URL." >&2
    exit 1
fi
echo "[+] Discord Webhook test message sent successfully!"

# Helper function to execute commands on master node (node-1)
run_on_master() {
    local cmd="$1"
    if ip addr show 2>/dev/null | grep -q "${NODE1_IP}" || [[ "${NODE1_IP}" == "localhost" ]] || [[ "${NODE1_IP}" == "127.0.0.1" ]]; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no "root@${NODE1_IP}" "${cmd}"
    fi
}

echo "[*] Configuring Proxmox VE Webhook Endpoint 'discord-alerts'..."
# Discord JSON embed payload using Proxmox Handlebars {{ escape ... }} and bounded fields (avoids Discord 2000/4096 char HTTP 400 on long vzdump reports)
# shellcheck disable=SC2016
DISCORD_BODY_JSON='{"embeds":[{"title":"🚨 Proxmox VE [{{ escape severity }}] — {{ escape title }}","description":"**Type :** `{{#if fields.type}}{{ escape fields.type }}{{else}}notification{{/if}}` • **Nœud :** `{{#if fields.hostname}}{{ escape fields.hostname }}{{else}}cluster{{/if}}`\nConsultez les journaux `/var/log/vzdump/` ou la Task History Proxmox pour le détail complet.","color":15105570,"footer":{"text":"Proxmox VE Notification Engine • #monitoring"}}]}'
DISCORD_BODY_B64=$(echo -n "${DISCORD_BODY_JSON}" | base64 -w 0)
HEADER_JSON_B64=$(echo -n "application/json" | base64 -w 0)

run_on_master "
    # Check if endpoint already exists
    if pvesh get /cluster/notifications/endpoints/webhook/discord-alerts >/dev/null 2>&1; then
        pvesh set /cluster/notifications/endpoints/webhook/discord-alerts \
            --url '${DISCORD_WEBHOOK_URL}' \
            --method 'post' \
            --header 'name=Content-Type,value=${HEADER_JSON_B64}' \
            --body '${DISCORD_BODY_B64}' \
            --comment 'Discord Webhook for Unified #monitoring Alerts'
    else
        pvesh create /cluster/notifications/endpoints/webhook \
            --name 'discord-alerts' \
            --url '${DISCORD_WEBHOOK_URL}' \
            --method 'post' \
            --header 'name=Content-Type,value=${HEADER_JSON_B64}' \
            --body '${DISCORD_BODY_B64}' \
            --comment 'Discord Webhook for Unified #monitoring Alerts'
    fi

    # Update default-matcher to route notifications to discord-alerts (mail-to-root disabled cleanly)
    pvesh set /cluster/notifications/matchers/default-matcher \
        --target discord-alerts \
        --mode 'all'
"

echo "[+] Proxmox VE Discord Webhook endpoint successfully registered and active!"
echo "=============================================================================="
