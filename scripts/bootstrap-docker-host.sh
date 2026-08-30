#!/usr/bin/env bash
# ==============================================================================
# Universal Docker Host Baseline Bootstrapper
# Target: Debian 12 (Bookworm) LXC Containers
# ==============================================================================
# Prepares any Debian LXC container to run Docker Compose stacks:
#   - Installs official Docker CE + Docker Compose Plugin
#   - Configures daemon log rotation (/etc/docker/daemon.json)
#   - Creates non-root application user and sets group permissions
#
# Usage:
#   ./scripts/bootstrap-docker-host.sh [APP_USER]
# ==============================================================================
set -euo pipefail

APP_USER="${1:-app}"

if [ "$(id -u)" -ne 0 ]; then
    echo "[-] Error: This script must be run as root." >&2
    exit 1
fi

echo "=============================================================================="
echo "    Universal Docker Host Bootstrapper (Target user: ${APP_USER})             "
echo "=============================================================================="

export DEBIAN_FRONTEND=noninteractive

# 1. Install prerequisites
echo "[*] Updating apt index and installing dependencies..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    sudo \
    jq \
    rsync \
    dnsutils \
    net-tools

# 2. Install official Docker CE repository
echo "[*] Setting up official Docker CE repository..."
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
fi

ARCH="$(dpkg --print-architecture)"
# shellcheck disable=SC1091
CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

apt-get update -qq
apt-get install -y --no-install-recommends \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

# 3. Configure Docker Daemon (Log Rotation & Storage)
echo "[*] Configuring /etc/docker/daemon.json..."
mkdir -p /etc/docker
cat <<DAEMON_EOF > /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
DAEMON_EOF

systemctl enable --now docker
systemctl restart docker

# 4. User setup & permissions
if [ -n "${APP_USER}" ] && [ "${APP_USER}" != "root" ]; then
    echo "[*] Configuring user '${APP_USER}'..."
    if ! id -u "${APP_USER}" &>/dev/null; then
        useradd -u 1000 -U -m -s /bin/bash "${APP_USER}" || true
    fi
    usermod -aG docker "${APP_USER}" || true
fi

echo "=============================================================================="
echo "[+] Docker Engine & Compose plugin successfully installed and active!"
echo "=============================================================================="
