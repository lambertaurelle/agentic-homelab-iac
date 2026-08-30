#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Configuration Parameters
# ==============================================================================
CTID=900
HOSTNAME="mgmt-devops"
STORAGE="local-lvm"       # Storage pool for the root disk
TEMPLATE_STORAGE="local"  # Storage pool where templates are stored
DISK_SIZE="16"
RAM=2048
SWAP=512
CORES=2
BRIDGE="vmbr0"
IP_CONFIG="ip=dhcp"       # Or set static: "ip=10.0.0.56/24,gw=10.0.0.1"

# ==============================================================================
# 1. Ensure Debian 12 Template Exists
# ==============================================================================
echo "[*] Updating Proxmox appliance template index..."
pveam update > /dev/null

TEMPLATE_NAME=$(pveam available -section system | awk '/debian-12-standard/ {print $2}' | sort -V | tail -n 1)

if [ -z "$TEMPLATE_NAME" ]; then
    echo "[-] Error: Could not find Debian 12 standard template in pveam catalog."
    exit 1
fi

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE_NAME"; then
    echo "[*] Downloading template $TEMPLATE_NAME to $TEMPLATE_STORAGE..."
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
fi

TEMPLATE_PATH="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

# ==============================================================================
# 2. Create the LXC Container
# ==============================================================================
if pct status "$CTID" >/dev/null 2>&1; then
    echo "[-] Container ID $CTID already exists. Choose a different CTID or remove the existing one."
    exit 1
fi

echo "[*] Creating LXC container ID $CTID ($HOSTNAME)..."
pct create "$CTID" "$TEMPLATE_PATH" \
    --hostname "$HOSTNAME" \
    --cores "$CORES" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRIDGE},${IP_CONFIG}" \
    --unprivileged 1 \
    --features nesting=1 \
    --onboot 1 \
    --start 0

# ==============================================================================
# 3. Boot Container & Wait for Network
# ==============================================================================
echo "[*] Starting container $CTID..."
pct start "$CTID"

echo "[*] Waiting for network connectivity..."
sleep 5
for i in {1..15}; do
    if pct exec "$CTID" -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
        echo "[+] Network is up."
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "[-] Timed out waiting for container network access."
        exit 1
    fi
    sleep 2
done

# ==============================================================================
# 4. Install Base Tools, OpenTofu, and Antigravity CLI
# ==============================================================================
echo "[*] Installing dependencies, OpenTofu, and Antigravity CLI inside container..."

# shellcheck disable=SC2016
pct exec "$CTID" -- bash -c '
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Update system & install core utilities
apt-get update
apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    gnupg \
    git \
    jq \
    sudo \
    rsync \
    unzip \
    openssh-client

# Install OpenTofu repository and package
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://get.opentofu.org/opentofu.gpg | tee /etc/apt/keyrings/opentofu.gpg >/dev/null
curl -fsSL https://packages.opentofu.org/opentofu/tofu/gpgkey | gpg --dearmor -o /etc/apt/keyrings/opentofu-repo.gpg >/dev/null
chmod a+r /etc/apt/keyrings/opentofu.gpg /etc/apt/keyrings/opentofu-repo.gpg

echo "deb [signed-by=/etc/apt/keyrings/opentofu.gpg,/etc/apt/keyrings/opentofu-repo.gpg] https://packages.opentofu.org/opentofu/tofu/any/ any main" \
    | tee /etc/apt/sources.list.d/opentofu.list

# Install 1Password CLI repository and verification policy
curl -sS https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main" \
    | tee /etc/apt/sources.list.d/1password.list
mkdir -p /etc/debsig/policies/AC2D62742012EA22/ && curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | tee /etc/debsig/policies/AC2D62742012EA22/1password.pol
mkdir -p /usr/share/debsig/keyrings/AC2D62742012EA22 && curl -sS https://downloads.1password.com/linux/keys/1password.asc | gpg --dearmor --output /usr/share/debsig/keyrings/AC2D62742012EA22/debsig.gpg

apt-get update
apt-get install -y tofu 1password-cli

# Install Antigravity CLI
curl -fsSL https://antigravity.google/cli/install.sh | bash

# Ensure binary paths and XDG runtime directory for 1Password CLI are loaded
loginctl enable-linger root || true
echo "export XDG_RUNTIME_DIR=\"/run/user/0\"" >> /root/.bashrc
echo "export XDG_RUNTIME_DIR=\"/run/user/0\"" >> /etc/profile
echo "export PATH=\"/root/.local/bin:\$PATH\"" >> /root/.bashrc
echo "export PATH=\"/root/.local/bin:\$PATH\"" >> /etc/profile

# Setup Antigravity 2.0 Remote Control service daemon
if [ -f "/root/homelab-iac/scripts/install-antigravity-remote.sh" ]; then
    /root/homelab-iac/scripts/install-antigravity-remote.sh install --name mgmt-devops --no-prompt || true
fi
'

echo "=============================================================================="
echo "[+] Management LXC ($CTID) successfully created and configured!"
echo "=============================================================================="
echo "To enter the container shell, run:"
echo "    pct enter $CTID"
echo "=============================================================================="
