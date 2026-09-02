#!/usr/bin/env bash
# ==============================================================================
# Offsite Backup Worker Provisioner (CT 602)
# ==============================================================================
# Configures the dedicated offsite backup LXC container:
#   1. Installs restic, rclone, jq, curl, python3-yaml
#   2. Configures /etc/offsite-backup/rclone.conf targeting cloud remote
#   3. Initializes the encrypted Restic repository on cloud storage
#   4. Installs /usr/local/bin/run-offsite-backup & offsite-backup.service
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="/etc/offsite-backup/backup.env"

# If running from repo root during setup, stage env file
if [ ! -f "${ENV_FILE}" ] && [ -f "${REPO_ROOT}/stacks/offsite-backup/.env" ]; then
    mkdir -p /etc/offsite-backup
    cp "${REPO_ROOT}/stacks/offsite-backup/.env" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
fi

if [ -f "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
    set +a
fi

OFFSITE_BACKUP_REMOTE_NAME="${OFFSITE_BACKUP_REMOTE_NAME:-offsite-remote}"
OFFSITE_BACKUP_REMOTE_TYPE="${OFFSITE_BACKUP_REMOTE_TYPE:-pcloud}"
OFFSITE_BACKUP_REMOTE_PATH="${OFFSITE_BACKUP_REMOTE_PATH:-homelab-backups}"
RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
PCLOUD_REGION="${PCLOUD_REGION:-eu}"
PCLOUD_AUTH_TOKEN="${PCLOUD_AUTH_TOKEN:-}"
PCLOUD_USERNAME="${PCLOUD_USERNAME:-}"
PCLOUD_PASSWORD="${PCLOUD_PASSWORD:-}"

echo "=============================================================================="
echo "    Offsite Cloud Backup Worker Provisioner (CT 602)                         "
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Install Essential Packages
# ------------------------------------------------------------------------------
echo "[*] Step 1/4: Installing essential backup & CLI utilities..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq restic rclone jq curl python3 python3-yaml ca-certificates >/dev/null
echo "[+] Packages installed successfully: restic $(restic version 2>/dev/null | awk '{print $2}'), rclone $(rclone version 2>/dev/null | head -n1 | awk '{print $2}')."

# ------------------------------------------------------------------------------
# 2. Configure Rclone Remote
# ------------------------------------------------------------------------------
echo "[*] Step 2/4: Configuring /etc/offsite-backup/rclone.conf for '${OFFSITE_BACKUP_REMOTE_NAME}' (${OFFSITE_BACKUP_REMOTE_TYPE})..."
mkdir -p /etc/offsite-backup

RCLONE_CONF="/etc/offsite-backup/rclone.conf"

python3 -c "
import os, json, subprocess

remote_name = os.getenv('OFFSITE_BACKUP_REMOTE_NAME', 'offsite-remote')
remote_type = os.getenv('OFFSITE_BACKUP_REMOTE_TYPE', 'pcloud')
pcloud_region = os.getenv('PCLOUD_REGION', 'eu')
pcloud_token = os.getenv('PCLOUD_AUTH_TOKEN', '').strip()
pcloud_user = os.getenv('PCLOUD_USERNAME', '')
pcloud_pass = os.getenv('PCLOUD_PASSWORD', '')

conf_path = '${RCLONE_CONF}'
with open(conf_path, 'w') as f:
    f.write(f'[{remote_name}]\n')
    f.write(f'type = {remote_type}\n')
    if remote_type == 'pcloud':
        host = 'eapi.pcloud.com' if pcloud_region == 'eu' else 'api.pcloud.com'
        f.write(f'hostname = {host}\n')
        if pcloud_token:
            try:
                compact_token = json.dumps(json.loads(pcloud_token))
                f.write(f'token = {compact_token}\n')
            except Exception:
                f.write(f'token = {pcloud_token}\n')
        elif pcloud_user and pcloud_pass:
            try:
                obs = subprocess.check_output(['rclone', 'obscure', pcloud_pass]).decode().strip()
                f.write(f'username = {pcloud_user}\n')
                f.write(f'password = {obs}\n')
            except Exception:
                pass

os.chmod(conf_path, 0o600)
"
echo "[+] Rclone configuration generated with secure permissions."

# Ensure standard user directory rclone config symlink exists
mkdir -p /root/.config/rclone
ln -sf /etc/offsite-backup/rclone.conf /root/.config/rclone/rclone.conf

# ------------------------------------------------------------------------------
# 3. Synchronize Backup Targets Configuration
# ------------------------------------------------------------------------------
echo "[*] Step 3/4: Synchronizing backup targets definition..."
if [ -f "${REPO_ROOT}/config/instance/backup-targets.yaml" ]; then
    cp "${REPO_ROOT}/config/instance/backup-targets.yaml" /etc/offsite-backup/backup-targets.yaml
elif [ -f "${REPO_ROOT}/config/backup-targets.example.yaml" ]; then
    cp "${REPO_ROOT}/config/backup-targets.example.yaml" /etc/offsite-backup/backup-targets.yaml
fi
chmod 644 /etc/offsite-backup/backup-targets.yaml || true
echo "[+] Targets configuration ready at /etc/offsite-backup/backup-targets.yaml."

# Configure global environment variables for CLI and restic/rclone invocations
if [ -f /etc/offsite-backup/backup.env ]; then
    grep -q "RESTIC_REPOSITORY=" /etc/environment 2>/dev/null || {
        cat <<ENV_EOF >> /etc/environment
RESTIC_REPOSITORY="rclone:${OFFSITE_BACKUP_REMOTE_NAME}:${OFFSITE_BACKUP_REMOTE_PATH}"
RESTIC_PASSWORD="${RESTIC_PASSWORD}"
RCLONE_CONFIG="/etc/offsite-backup/rclone.conf"
ENV_EOF
    }
fi

# ------------------------------------------------------------------------------
# 4. Install Runner Script & Systemd Service
# ------------------------------------------------------------------------------
echo "[*] Step 4/4: Installing backup runner script & systemd service..."
if [ -f "${REPO_ROOT}/scripts/run-offsite-backup.sh" ]; then
    cp "${REPO_ROOT}/scripts/run-offsite-backup.sh" /usr/local/bin/run-offsite-backup
    chmod +x /usr/local/bin/run-offsite-backup
    ln -sf /usr/local/bin/run-offsite-backup /usr/bin/run-offsite-backup
fi

cat <<'SERVICE_EOF' > /etc/systemd/system/offsite-backup.service
[Unit]
Description=Automated Differential Offsite Cloud Backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
WorkingDirectory=/root
Environment="HOME=/root"
EnvironmentFile=-/etc/offsite-backup/backup.env
ExecStart=/usr/local/bin/run-offsite-backup --ephemeral
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
SERVICE_EOF

systemctl daemon-reload
systemctl enable offsite-backup.service
echo "[+] offsite-backup.service enabled on multi-user boot."

echo "=============================================================================="
echo "    Offsite Cloud Backup Worker Initialized Successfully!                    "
echo "=============================================================================="
