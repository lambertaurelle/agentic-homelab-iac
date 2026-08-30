#!/usr/bin/env bash
# ==============================================================================
# Cloudflare Tunnel (cloudflared) Automated Installer & Service Setup
# Target: Debian 12 (Bookworm) LXC Container (CT 510 on node-1 / CT 511 on node-2)
# ==============================================================================
set -euo pipefail

echo "=============================================================================="
echo "    Cloudflare Tunnel (cloudflared) Installer & HA Service Setup             "
echo "=============================================================================="

# Ensure running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

# Load secrets if present in repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || echo "")"
if [ -n "${REPO_ROOT}" ] && [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1090,SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

TUNNEL_TOKEN="${1:-${TUNNEL_TOKEN:-${CLOUDFLARE_TUNNEL_TOKEN:-}}}"

if [ -z "${TUNNEL_TOKEN}" ]; then
    if [ -t 0 ]; then
        read -r -s -p "Enter Cloudflare Tunnel Token: " TUNNEL_TOKEN
        echo ""
    fi
fi

if [ -z "${TUNNEL_TOKEN}" ]; then
    echo "[-] Error: TUNNEL_TOKEN is required. Pass as \$1, export TUNNEL_TOKEN, or set CLOUDFLARE_TUNNEL_TOKEN in homelab-secrets.env." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------------------
# 1. Install Prerequisites
# ------------------------------------------------------------------------------
echo "[*] Installing prerequisite tools (curl, ca-certificates, gnupg, systemd)..."
apt-get update
apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    gpg \
    lsb-release \
    procps \
    sudo

# ------------------------------------------------------------------------------
# 2. Download and Install Cloudflared Debian Package
# ------------------------------------------------------------------------------
echo "[*] Downloading and installing official cloudflared binary package..."
TMP_DEB="/tmp/cloudflared-linux-amd64.deb"
curl -fsSL --retry 3 -o "${TMP_DEB}" "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb"
dpkg -i "${TMP_DEB}"
rm -f "${TMP_DEB}"

echo "[+] cloudflared binary installed: $(cloudflared --version)"

# ------------------------------------------------------------------------------
# 3. Configure and Install Systemd Service
# ------------------------------------------------------------------------------
echo "[*] Installing and configuring cloudflared systemd service with tunnel token..."
# Uninstall existing service if present to allow idempotent re-installation
if systemctl is-active --quiet cloudflared || [ -f /etc/systemd/system/cloudflared.service ]; then
    systemctl stop cloudflared 2>/dev/null || true
    cloudflared service uninstall 2>/dev/null || true
fi

cloudflared service install "${TUNNEL_TOKEN}"

echo "[*] Enabling and starting cloudflared systemd service..."
systemctl daemon-reload
systemctl enable cloudflared
systemctl start cloudflared

echo "[+] Verifying cloudflared service status..."
systemctl is-active --quiet cloudflared && echo "[+] cloudflared is running successfully."

echo "=============================================================================="
echo "    Cloudflare Tunnel Connector installed and running successfully!           "
echo "=============================================================================="
