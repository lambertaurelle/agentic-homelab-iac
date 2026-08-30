#!/usr/bin/env bash
# ==============================================================================
# Homelab Secrets Bootstrapper & Configuration Generator
# ==============================================================================
# Slices secrets from secrets.env (or 1Password) into:
#   1. tofu/terraform.tfvars (Baseline Core Infrastructure)
#   2. stacks/monitoring/.env
#   3. Calls scripts/instance/bootstrap-instance-secrets.sh (if present)
#
# Usage:
#   ./scripts/bootstrap-secrets.sh                   # Load from secrets.env / homelab-secrets.env
#   ./scripts/bootstrap-secrets.sh --op              # Fetch directly from 1Password Secure Note
#   ./scripts/bootstrap-secrets.sh path/to/env.file  # Load from custom env file
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

USE_OP=false
SECRETS_FILE=""

# Auto-detect default secrets file
if [ -f "${REPO_ROOT}/secrets.env" ]; then
    SECRETS_FILE="${REPO_ROOT}/secrets.env"
elif [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    SECRETS_FILE="${REPO_ROOT}/homelab-secrets.env"
else
    SECRETS_FILE="${REPO_ROOT}/secrets.env"
fi

# Parse CLI flags
while [ $# -gt 0 ]; do
    case "$1" in
        --op|-op)
            USE_OP=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--op] [path/to/secrets.env]"
            echo "  --op    Fetch secrets directly from 1Password Secure Note before bootstrapping"
            exit 0
            ;;
        *)
            SECRETS_FILE="$1"
            shift
            ;;
    esac
done

echo "=============================================================================="
echo "    Homelab Secrets Bootstrapper                                              "
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. 1Password Secure Note Ingestion (--op)
# ------------------------------------------------------------------------------
if [ "${USE_OP}" = true ]; then
    echo "[*] Fetching master secrets from 1Password Secure Note..."
    if ! command -v op >/dev/null 2>&1; then
        echo "[-] Error: 1Password CLI ('op') is not installed or not in PATH." >&2
        exit 1
    fi

    if ! op whoami >/dev/null 2>&1; then
        echo "[-] Error: 1Password session not authenticated. Run 'eval \$(op signin)'." >&2
        exit 1
    fi

    op read "op://Private/Homelab Master Secrets/notesPlain" > "${SECRETS_FILE}"
    chmod 600 "${SECRETS_FILE}"
    echo "[+] Successfully loaded secrets into ${SECRETS_FILE}"
fi

if [ ! -f "${SECRETS_FILE}" ]; then
    echo "[-] Error: Secrets file not found at: ${SECRETS_FILE}" >&2
    echo "    Please create it using 'secrets.env.example' or run with '--op'." >&2
    exit 1
fi

echo "[*] Loading and normalizing secrets from: ${SECRETS_FILE}"
CLEAN_SECRETS_FILE=$(mktemp)
trap 'rm -f "${CLEAN_SECRETS_FILE}"' EXIT

python3 -c '
import sys, re
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as f:
    for line in f:
        line_s = line.strip()
        if not line_s or line_s.startswith("#"):
            print(line, end="")
            continue
        m = re.match(r"^([A-Za-z0-9_]+)\s*[:=]\s*(.*)$", line_s)
        if m:
            k, v = m.group(1), m.group(2)
            if v.startswith("\x27") and v.endswith("\x27"):
                print(f"{k}={v}")
            elif (v.startswith("\"") and v.endswith("\"")) and "$" in v:
                inner = v[1:-1]
                print(f"{k}=\x27{inner}\x27")
            elif "$" in v:
                print(f"{k}=\x27{v}\x27")
            elif v.startswith("\"") and v.endswith("\""):
                print(f"{k}={v}")
            else:
                v_esc = v.replace("\"", "\\\"")
                print(f"{k}=\"{v_esc}\"")
        else:
            print(line, end="")
' "${SECRETS_FILE}" > "${CLEAN_SECRETS_FILE}"

cp "${CLEAN_SECRETS_FILE}" "${SECRETS_FILE}"
chmod 600 "${SECRETS_FILE}"

echo "[*] Sourcing environment from ${SECRETS_FILE}..."
set -a
# shellcheck disable=SC1090
. "${SECRETS_FILE}"
set +a

# ------------------------------------------------------------------------------
# 2. Defaults & Variable Normalization
# ------------------------------------------------------------------------------
NODE1_IP="${NODE1_IP:-${PROXMOX_NODE_IP:-10.0.0.10}}"
NODE2_IP="${NODE2_IP:-${TUXMOX_NODE_IP:-10.0.0.20}}"

ADGUARD_PRIMARY_IP="${ADGUARD_PRIMARY_IP:-10.0.0.201}"
ADGUARD_SECONDARY_IP="${ADGUARD_SECONDARY_IP:-10.0.0.202}"
UPSTREAM_DNS_IP="${UPSTREAM_DNS_IP:-10.0.0.101}"
DEFAULT_GATEWAY_IP="${DEFAULT_GATEWAY_IP:-10.0.0.1}"

UTILITY_NODE_NAME="${UTILITY_NODE_NAME:-node-1}"
COMPUTE_NODE_NAME="${COMPUTE_NODE_NAME:-node-2}"
APP_NODE_NAME="${APP_NODE_NAME:-${COMPUTE_NODE_NAME}}"

PROXMOX_ENDPOINT="${PROXMOX_ENDPOINT:-https://${NODE1_IP}:8006/}"
PROXMOX_INSECURE="${PROXMOX_INSECURE:-true}"

if [ -z "${PROXMOX_API_TOKEN:-}" ]; then
    echo "[-] Error: PROXMOX_API_TOKEN must be set in ${SECRETS_FILE}" >&2
    exit 1
fi

SSH_KEY_MGMT="${SSH_KEY_MGMT:-}"
SSH_KEY_NODE1="${SSH_KEY_NODE1:-${SSH_KEY_PROXMOX:-}}"
SSH_KEY_NODE2="${SSH_KEY_NODE2:-${SSH_KEY_TUXMOX:-}}"

if [ -z "${SSH_KEY_MGMT}" ] || [ -z "${SSH_KEY_NODE1}" ] || [ -z "${SSH_KEY_NODE2}" ]; then
    echo "[-] Error: SSH_KEY_MGMT, SSH_KEY_NODE1 (or SSH_KEY_PROXMOX), and SSH_KEY_NODE2 (or SSH_KEY_TUXMOX) must all be defined." >&2
    exit 1
fi

# Normalize AdGuard IP with subnet CIDR notation
if [[ "${ADGUARD_PRIMARY_IP}" == */* ]]; then
    ADGUARD_PRIMARY_IPV4="${ADGUARD_PRIMARY_IP}"
else
    ADGUARD_PRIMARY_IPV4="${ADGUARD_PRIMARY_IP}/24"
fi

if [[ "${ADGUARD_SECONDARY_IP}" == */* ]]; then
    ADGUARD_SECONDARY_IPV4="${ADGUARD_SECONDARY_IP}"
else
    ADGUARD_SECONDARY_IPV4="${ADGUARD_SECONDARY_IP}/24"
fi

# Hostname defaults
CLOUDFLARED_PRIMARY_HOSTNAME="${CLOUDFLARED_PRIMARY_HOSTNAME:-cloudflared-primary}"
CLOUDFLARED_SECONDARY_HOSTNAME="${CLOUDFLARED_SECONDARY_HOSTNAME:-cloudflared-secondary}"
ADGUARD_PRIMARY_HOSTNAME="${ADGUARD_PRIMARY_HOSTNAME:-adguard-primary}"
ADGUARD_SECONDARY_HOSTNAME="${ADGUARD_SECONDARY_HOSTNAME:-adguard-secondary}"
MONITORING_HOSTNAME="${MONITORING_HOSTNAME:-monitoring}"

# Build HCL-formatted SSH public keys array
SSH_KEYS_HCL=$(cat <<SSH_KEYS_EOF
[
  "${SSH_KEY_MGMT}",
  "${SSH_KEY_NODE1}",
  "${SSH_KEY_NODE2}"
]
SSH_KEYS_EOF
)

# ------------------------------------------------------------------------------
# 3. Generate tofu/terraform.tfvars (Baseline Core)
# ------------------------------------------------------------------------------
TOFU_TFVARS="${REPO_ROOT}/tofu/terraform.tfvars"
echo "[*] Generating baseline ${TOFU_TFVARS}..."

cat <<TFVARS_EOF > "${TOFU_TFVARS}"
# ==============================================================================
# Proxmox VE Connection Details
# ==============================================================================
proxmox_endpoint  = "${PROXMOX_ENDPOINT}"
proxmox_api_token = "${PROXMOX_API_TOKEN}"
proxmox_insecure  = ${PROXMOX_INSECURE}

# ==============================================================================
# Cluster Nodes
# ==============================================================================
utility_node_name    = "${UTILITY_NODE_NAME}"
utility_node_address = "${NODE1_IP}"

compute_node_name    = "${COMPUTE_NODE_NAME}"
compute_node_address = "${NODE2_IP}"

app_node_name        = "${APP_NODE_NAME}"

# ==============================================================================
# AdGuard Home Primary (CT 501 on utility node)
# ==============================================================================
adguard_primary_ct_id            = 501
adguard_primary_hostname         = "${ADGUARD_PRIMARY_HOSTNAME}"
adguard_primary_cores            = 2
adguard_primary_memory           = 1024
adguard_primary_swap             = 512
adguard_primary_disk_storage     = "local-lvm"
adguard_primary_disk_size        = 10
adguard_primary_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
adguard_primary_network_bridge   = "vmbr0"
adguard_primary_mac_address      = "bc:24:11:00:05:01"
adguard_primary_ipv4_address     = "${ADGUARD_PRIMARY_IPV4}"
adguard_primary_ipv4_gateway     = "${DEFAULT_GATEWAY_IP}"
adguard_dns_servers              = ["${UPSTREAM_DNS_IP}"]
adguard_primary_ssh_public_keys  = ${SSH_KEYS_HCL}
adguard_primary_unprivileged     = false

# ==============================================================================
# AdGuard Home Secondary (CT 502 on compute node)
# ==============================================================================
adguard_secondary_ct_id            = 502
adguard_secondary_hostname         = "${ADGUARD_SECONDARY_HOSTNAME}"
adguard_secondary_cores            = 2
adguard_secondary_memory           = 1024
adguard_secondary_swap             = 512
adguard_secondary_disk_storage     = "local-lvm"
adguard_secondary_disk_size        = 10
adguard_secondary_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
adguard_secondary_network_bridge   = "vmbr0"
adguard_secondary_mac_address      = "bc:24:11:00:05:02"
adguard_secondary_ipv4_address     = "${ADGUARD_SECONDARY_IPV4}"
adguard_secondary_ipv4_gateway     = "${DEFAULT_GATEWAY_IP}"
adguard_secondary_ssh_public_keys  = ${SSH_KEYS_HCL}
adguard_secondary_unprivileged     = false

# ==============================================================================
# Cloudflared Primary (CT 510 on utility node)
# ==============================================================================
cloudflared_primary_ct_id            = 510
cloudflared_primary_hostname         = "${CLOUDFLARED_PRIMARY_HOSTNAME}"
cloudflared_primary_cores            = 1
cloudflared_primary_memory           = 512
cloudflared_primary_swap             = 256
cloudflared_primary_disk_storage     = "local-lvm"
cloudflared_primary_disk_size        = 8
cloudflared_primary_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
cloudflared_primary_network_bridge   = "vmbr0"
cloudflared_primary_mac_address      = "bc:24:11:00:05:10"
cloudflared_primary_ipv4_address     = "dhcp"
cloudflared_primary_ssh_public_keys  = ${SSH_KEYS_HCL}
cloudflared_primary_unprivileged     = true

# ==============================================================================
# Cloudflared Secondary (CT 511 on compute node)
# ==============================================================================
cloudflared_secondary_ct_id            = 511
cloudflared_secondary_hostname         = "${CLOUDFLARED_SECONDARY_HOSTNAME}"
cloudflared_secondary_cores            = 1
cloudflared_secondary_memory           = 512
cloudflared_secondary_swap             = 256
cloudflared_secondary_disk_storage     = "local-lvm"
cloudflared_secondary_disk_size        = 8
cloudflared_secondary_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
cloudflared_secondary_network_bridge   = "vmbr0"
cloudflared_secondary_mac_address      = "bc:24:11:00:05:11"
cloudflared_secondary_ipv4_address     = "dhcp"
cloudflared_secondary_ssh_public_keys  = ${SSH_KEYS_HCL}
cloudflared_secondary_unprivileged     = true

# ==============================================================================
# Monitoring (Uptime Kuma) LXC Configuration (CT 601 on utility node)
# ==============================================================================
monitoring_ct_id            = 601
monitoring_hostname         = "${MONITORING_HOSTNAME}"
monitoring_cores            = 2
monitoring_memory           = 1024
monitoring_swap             = 512
monitoring_disk_storage     = "local-lvm"
monitoring_disk_size        = 16
monitoring_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
monitoring_network_bridge   = "vmbr0"
monitoring_mac_address      = "bc:24:11:00:06:01"
monitoring_ipv4_address     = "dhcp"
monitoring_ssh_public_keys  = ${SSH_KEYS_HCL}
monitoring_unprivileged     = false
TFVARS_EOF

chmod 600 "${TOFU_TFVARS}"

# ------------------------------------------------------------------------------
# 4. Generate Core Baseline stacks/monitoring/.env
# ------------------------------------------------------------------------------
mkdir -p "${REPO_ROOT}/stacks/monitoring"
cat <<MONITORING_EOF > "${REPO_ROOT}/stacks/monitoring/.env"
UPTIME_KUMA_PORT=3001
UPTIME_KUMA_ADMIN_USER=${UPTIME_KUMA_ADMIN_USER:-admin}
UPTIME_KUMA_ADMIN_PASS=${UPTIME_KUMA_ADMIN_PASS:-}
UPTIME_KUMA_ADMIN_HASH=${UPTIME_KUMA_ADMIN_HASH:-}
UPTIME_KUMA_BASE_URL=${UPTIME_KUMA_BASE_URL:-}
DISCORD_WEBHOOK_URL=${DISCORD_WEBHOOK_URL:-${DISCORD_MONITORING_WEBHOOK_URL:-}}
DISCORD_MONITORING_WEBHOOK_URL=${DISCORD_MONITORING_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}
DISCORD_SECURITY_WEBHOOK_URL=${DISCORD_SECURITY_WEBHOOK_URL:-}
MONITORING_EOF
chmod 600 "${REPO_ROOT}/stacks/monitoring/.env"
echo "[+] Sliced baseline .env for stacks/monitoring"

# ------------------------------------------------------------------------------
# 5. Invoke Instance Hook (if present)
# ------------------------------------------------------------------------------
INSTANCE_HOOK="${REPO_ROOT}/scripts/instance/bootstrap-instance-secrets.sh"
if [ -f "${INSTANCE_HOOK}" ]; then
    echo "[*] Found instance secrets hook at ${INSTANCE_HOOK}. Executing..."
    bash "${INSTANCE_HOOK}"
fi

if command -v tofu >/dev/null 2>&1; then
    tofu fmt "${TOFU_TFVARS}" >/dev/null 2>&1 || true
fi

echo "=============================================================================="
echo "[+] All environment and configuration files successfully generated!"
echo "=============================================================================="
