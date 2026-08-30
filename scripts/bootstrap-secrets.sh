#!/usr/bin/env bash
# ==============================================================================
# Homelab Secrets Bootstrapper & Configuration Generator
# ==============================================================================
# Slices secrets from secrets.env (or 1Password) into:
#   1. tofu/terraform.tfvars
#   2. stacks/seedbox/.env
#   3. stacks/immich/.env
#   4. stacks/teamspeak/.env
#   5. stacks/monitoring/.env
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

echo "[*] Sourcing environment from ${SECRETS_FILE}..."
set -a
# shellcheck disable=SC1090
. "${SECRETS_FILE}"
set +a

# ------------------------------------------------------------------------------
# 2. Defaults & Variable Normalization
# ------------------------------------------------------------------------------
PROXMOX_NODE_IP="${PROXMOX_NODE_IP:-10.0.0.10}"
TUXMOX_NODE_IP="${TUXMOX_NODE_IP:-10.0.0.20}"
NAS_IP="${NAS_IP:-10.0.0.4}"
DEFAULT_GATEWAY_IP="${DEFAULT_GATEWAY_IP:-10.0.0.1}"
LAN_SUBNET_CIDR="${LAN_SUBNET_CIDR:-10.0.0.0/24}"
ADGUARD_PRIMARY_IP="${ADGUARD_PRIMARY_IP:-10.0.0.201}"
ADGUARD_SECONDARY_IP="${ADGUARD_SECONDARY_IP:-10.0.0.202}"
UPSTREAM_DNS_IP="${UPSTREAM_DNS_IP:-10.0.0.101}"

PLEX_IP="${PLEX_IP:-10.0.0.151}"
AUDIOBOOKSHELF_IP="${AUDIOBOOKSHELF_IP:-10.0.0.152}"
SEEDBOX_IP="${SEEDBOX_IP:-10.0.0.161}"
IMMICH_IP="${IMMICH_IP:-10.0.0.171}"
TEAMSPEAK_IP="${TEAMSPEAK_IP:-10.0.0.61}"
CLOUDFLARED_PRIMARY_IP="${CLOUDFLARED_PRIMARY_IP:-10.0.0.66}"
CLOUDFLARED_SECONDARY_IP="${CLOUDFLARED_SECONDARY_IP:-10.0.0.65}"
MONITORING_IP="${MONITORING_IP:-10.0.0.62}"
MGMT_DEVOPS_IP="${MGMT_DEVOPS_IP:-10.0.0.56}"
WORKSTATION_IP="${WORKSTATION_IP:-10.0.0.57}"

UTILITY_NODE_NAME="${UTILITY_NODE_NAME:-proxmox}"
COMPUTE_NODE_NAME="${COMPUTE_NODE_NAME:-tuxmox}"
APP_NODE_NAME="${APP_NODE_NAME:-${COMPUTE_NODE_NAME}}"

PROXMOX_ENDPOINT="${PROXMOX_ENDPOINT:-https://${PROXMOX_NODE_IP}:8006/}"
PROXMOX_INSECURE="${PROXMOX_INSECURE:-true}"

if [ -z "${PROXMOX_API_TOKEN:-}" ]; then
    echo "[-] Error: PROXMOX_API_TOKEN must be set in ${SECRETS_FILE}" >&2
    exit 1
fi

SSH_KEY_MGMT="${SSH_KEY_MGMT:-}"
SSH_KEY_PROXMOX="${SSH_KEY_PROXMOX:-}"
SSH_KEY_TUXMOX="${SSH_KEY_TUXMOX:-}"

if [ -z "${SSH_KEY_MGMT}" ] || [ -z "${SSH_KEY_PROXMOX}" ] || [ -z "${SSH_KEY_TUXMOX}" ]; then
    echo "[-] Error: SSH_KEY_MGMT, SSH_KEY_PROXMOX, and SSH_KEY_TUXMOX must all be defined." >&2
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
PLEX_HOSTNAME="${PLEX_HOSTNAME:-plex}"
AUDIOBOOKSHELF_HOSTNAME="${AUDIOBOOKSHELF_HOSTNAME:-audiobookshelf}"
TEAMSPEAK_HOSTNAME="${TEAMSPEAK_HOSTNAME:-teamspeak}"
SEEDBOX_HOSTNAME="${SEEDBOX_HOSTNAME:-seedbox}"
IMMICH_HOSTNAME="${IMMICH_HOSTNAME:-immich}"
CLOUDFLARED_PRIMARY_HOSTNAME="${CLOUDFLARED_PRIMARY_HOSTNAME:-cloudflared-primary}"
CLOUDFLARED_SECONDARY_HOSTNAME="${CLOUDFLARED_SECONDARY_HOSTNAME:-cloudflared-secondary}"
ADGUARD_PRIMARY_HOSTNAME="${ADGUARD_PRIMARY_HOSTNAME:-adguard-primary}"
ADGUARD_SECONDARY_HOSTNAME="${ADGUARD_SECONDARY_HOSTNAME:-adguard-secondary}"
MONITORING_HOSTNAME="${MONITORING_HOSTNAME:-monitoring}"
WORKSTATION_HOSTNAME="${WORKSTATION_HOSTNAME:-workstation}"

# Build HCL-formatted SSH public keys array
SSH_KEYS_HCL=$(cat <<SSH_KEYS_EOF
[
  "${SSH_KEY_MGMT}",
  "${SSH_KEY_PROXMOX}",
  "${SSH_KEY_TUXMOX}"
]
SSH_KEYS_EOF
)

# ------------------------------------------------------------------------------
# 3. Generate tofu/terraform.tfvars
# ------------------------------------------------------------------------------
TOFU_TFVARS="${REPO_ROOT}/tofu/terraform.tfvars"
echo "[*] Generating ${TOFU_TFVARS}..."

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
utility_node_address = "${PROXMOX_NODE_IP}"

compute_node_name    = "${COMPUTE_NODE_NAME}"
compute_node_address = "${TUXMOX_NODE_IP}"

app_node_name        = "${APP_NODE_NAME}"

# ==============================================================================
# Plex LXC Configuration (CT 101)
# ==============================================================================
plex_ct_id            = 101
plex_hostname         = "${PLEX_HOSTNAME}"
plex_cores            = 4
plex_memory           = 4096
plex_swap             = 1024
plex_disk_storage     = "local-lvm"
plex_disk_size        = 50
plex_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
plex_network_bridge   = "vmbr0"
plex_mac_address      = "bc:24:11:00:01:01"
plex_ipv4_address     = "dhcp"
plex_ssh_public_keys  = ${SSH_KEYS_HCL}
plex_unprivileged     = false

# ==============================================================================
# Audiobookshelf LXC Configuration (CT 102)
# ==============================================================================
audiobookshelf_ct_id            = 102
audiobookshelf_hostname         = "${AUDIOBOOKSHELF_HOSTNAME}"
audiobookshelf_cores            = 2
audiobookshelf_memory           = 2048
audiobookshelf_swap             = 512
audiobookshelf_disk_storage     = "local-lvm"
audiobookshelf_disk_size        = 16
audiobookshelf_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
audiobookshelf_network_bridge   = "vmbr0"
audiobookshelf_mac_address      = "bc:24:11:00:01:02"
audiobookshelf_ipv4_address     = "dhcp"
audiobookshelf_ssh_public_keys  = ${SSH_KEYS_HCL}
audiobookshelf_unprivileged     = false

# ==============================================================================
# Seedbox Stack LXC Configuration (CT 201)
# ==============================================================================
seedbox_ct_id            = 201
seedbox_hostname         = "${SEEDBOX_HOSTNAME}"
seedbox_cores            = 4
seedbox_memory           = 4096
seedbox_swap             = 1024
seedbox_disk_storage     = "local-lvm"
seedbox_disk_size        = 40
seedbox_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
seedbox_network_bridge   = "vmbr0"
seedbox_mac_address      = "bc:24:11:00:02:01"
seedbox_ipv4_address     = "dhcp"
seedbox_ssh_public_keys  = ${SSH_KEYS_HCL}
seedbox_unprivileged     = false

# ==============================================================================
# Immich LXC Configuration (CT 301)
# ==============================================================================
immich_ct_id            = 301
immich_hostname         = "${IMMICH_HOSTNAME}"
immich_cores            = 6
immich_memory           = 8192
immich_swap             = 2048
immich_disk_storage     = "local-lvm"
immich_disk_size        = 50
immich_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
immich_network_bridge   = "vmbr0"
immich_mac_address      = "bc:24:11:00:03:01"
immich_ipv4_address     = "dhcp"
immich_ssh_public_keys  = ${SSH_KEYS_HCL}
immich_unprivileged     = false

# ==============================================================================
# TeamSpeak LXC Configuration (CT 401)
# ==============================================================================
teamspeak_ct_id            = 401
teamspeak_hostname         = "${TEAMSPEAK_HOSTNAME}"
teamspeak_cores            = 2
teamspeak_memory           = 2048
teamspeak_swap             = 512
teamspeak_disk_storage     = "local-lvm"
teamspeak_disk_size        = 20
teamspeak_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
teamspeak_network_bridge   = "vmbr0"
teamspeak_mac_address      = "bc:24:11:00:04:01"
teamspeak_ipv4_address     = "dhcp"
teamspeak_ssh_public_keys  = ${SSH_KEYS_HCL}
teamspeak_unprivileged     = false

# ==============================================================================
# AdGuard Home Primary (CT 501 on proxmox)
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
# AdGuard Home Secondary (CT 502 on tuxmox)
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
# Cloudflared Primary (CT 510 on proxmox)
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
# Cloudflared Secondary (CT 511 on tuxmox)
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
# Monitoring (Uptime Kuma) LXC Configuration (CT 601 on proxmox)
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

# ==============================================================================
# Workstation LXC Configuration (CT 901 on tuxmox)
# ==============================================================================
workstation_ct_id            = 901
workstation_hostname         = "${WORKSTATION_HOSTNAME}"
workstation_cores            = 4
workstation_memory           = 8192
workstation_swap             = 2048
workstation_disk_storage     = "local-lvm"
workstation_disk_size        = 40
workstation_template_file_id = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
workstation_network_bridge   = "vmbr0"
workstation_mac_address      = "bc:24:11:00:09:01"
workstation_ipv4_address     = "dhcp"
workstation_ssh_public_keys  = ${SSH_KEYS_HCL}
workstation_unprivileged     = true
TFVARS_EOF

chmod 600 "${TOFU_TFVARS}"
if command -v tofu >/dev/null 2>&1; then
    tofu fmt "${TOFU_TFVARS}" >/dev/null 2>&1 || true
fi
echo "[+] Generated ${TOFU_TFVARS}"

# ------------------------------------------------------------------------------
# 4. Generate stacks/*/.env files
# ------------------------------------------------------------------------------
mkdir -p "${REPO_ROOT}/stacks/seedbox"
cat <<SEEDBOX_EOF > "${REPO_ROOT}/stacks/seedbox/.env"
VPN_SERVICE_PROVIDER=${VPN_SERVICE_PROVIDER:-airvpn}
VPN_TYPE=${VPN_TYPE:-wireguard}
WIREGUARD_PRIVATE_KEY=${WIREGUARD_PRIVATE_KEY:-}
WIREGUARD_PRESHARED_KEY=${WIREGUARD_PRESHARED_KEY:-}
WIREGUARD_ADDRESSES=${WIREGUARD_ADDRESSES:-}
FIREWALL_VPN_INPUT_PORTS=${FIREWALL_VPN_INPUT_PORTS:-64321}
FIREWALL_OUTBOUND_SUBNETS=${FIREWALL_OUTBOUND_SUBNETS:-${LAN_SUBNET_CIDR}}
TZ=${IMMICH_TZ:-Europe/Paris}
PUID=1027
PGID=65536
SEEDBOX_DATA_PATH=${SEEDBOX_DATA_PATH:-/opt/seedbox/data}
SEEDBOX_TORRENTS_PATH=${SEEDBOX_TORRENTS_PATH:-/mnt/nas/data/torrents}
SEEDBOX_EOF
chmod 600 "${REPO_ROOT}/stacks/seedbox/.env"

mkdir -p "${REPO_ROOT}/stacks/immich"
cat <<IMMICH_EOF > "${REPO_ROOT}/stacks/immich/.env"
UPLOAD_LOCATION=${IMMICH_UPLOAD_LOCATION:-/mnt/nas/photos/library}
DB_DATA_LOCATION=${IMMICH_DB_DATA_LOCATION:-/opt/immich/data/postgres}
THUMBS_LOCATION=${IMMICH_THUMBS_LOCATION:-/opt/immich/data/thumbs}
MODEL_CACHE_LOCATION=${IMMICH_MODEL_CACHE_LOCATION:-/opt/immich/data/model-cache}
TZ=${IMMICH_TZ:-Europe/Paris}
IMMICH_VERSION=${IMMICH_VERSION:-release}
DB_PASSWORD=${IMMICH_DB_PASSWORD:-}
DB_USERNAME=${IMMICH_DB_USERNAME:-immich}
DB_DATABASE_NAME=${IMMICH_DB_DATABASE_NAME:-immich}
IMMICH_EOF
chmod 600 "${REPO_ROOT}/stacks/immich/.env"

mkdir -p "${REPO_ROOT}/stacks/teamspeak"
cat <<TEAMSPEAK_EOF > "${REPO_ROOT}/stacks/teamspeak/.env"
# TeamSpeak 6 Stack Configuration
# Native SQLite embedded database in /opt/teamspeak/config
TEAMSPEAK_EOF
chmod 600 "${REPO_ROOT}/stacks/teamspeak/.env"

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

echo "[+] Sliced .env files into stacks/ (seedbox, immich, teamspeak, monitoring)"
echo "=============================================================================="
echo "[+] All environment and configuration files successfully generated!"
echo "=============================================================================="
