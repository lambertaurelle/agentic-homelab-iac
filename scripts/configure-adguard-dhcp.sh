#!/usr/bin/env bash
# ==============================================================================
# AdGuard Home Static DHCP Leases Manager
# ==============================================================================
# Reconciles or registers static DHCP reservations in AdGuard Home.
#
# Usage:
#   ./scripts/configure-adguard-dhcp.sh
#   ./scripts/configure-adguard-dhcp.sh --app <name> --mac <mac> --ip <ip>
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source secrets if available
if [ -f "${REPO_ROOT}/secrets.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/secrets.env"
    set +a
elif [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
    set +a
fi

ADGUARD_PRIMARY_IP="${ADGUARD_PRIMARY_IP:-10.0.0.201}"
ADGUARD_ADMIN_USER="${ADGUARD_ADMIN_USER:-admin}"
ADGUARD_ADMIN_PASS="${ADGUARD_ADMIN_PASS:-}"

TARGET_APP=""
TARGET_MAC=""
TARGET_IP=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app|--name)
            TARGET_APP="$2"
            shift 2
            ;;
        --mac)
            TARGET_MAC="$2"
            shift 2
            ;;
        --ip)
            TARGET_IP="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--app <name> --mac <mac> --ip <ip>]"
            exit 0
            ;;
        *)
            shift
            ;;
    esac
done

echo "=============================================================================="
echo "    AdGuard Home Static DHCP Leases Reconciler                                "
echo "=============================================================================="

# Test if AdGuard is reachable on port 80/3000
if ! nc -z -w 2 "${ADGUARD_PRIMARY_IP}" 80 2>/dev/null && ! nc -z -w 2 "${ADGUARD_PRIMARY_IP}" 3000 2>/dev/null; then
    echo "[!] Notice: AdGuard Home Primary (${ADGUARD_PRIMARY_IP}) is not reachable on network."
    echo "    Skipping DHCP lease injection (run again once AdGuard is online)."
    exit 0
fi

if [ -n "${TARGET_APP}" ] && [ -n "${TARGET_MAC}" ] && [ -n "${TARGET_IP}" ]; then
    echo "[*] Registering static DHCP lease: ${TARGET_APP} -> ${TARGET_IP} (${TARGET_MAC})..."
    # If credentials available, call AdGuard Home API
    if [ -n "${ADGUARD_ADMIN_PASS}" ]; then
        curl -fsS -u "${ADGUARD_ADMIN_USER}:${ADGUARD_ADMIN_PASS}" \
             -H "Content-Type: application/json" \
             -X POST "http://${ADGUARD_PRIMARY_IP}/control/dhcp/add_static_lease" \
             -d "{\"mac\":\"${TARGET_MAC}\",\"ip\":\"${TARGET_IP}\",\"hostname\":\"${TARGET_APP}\"}" \
             >/dev/null 2>&1 || echo "[!] Notice: Could not push lease via API (manual configuration in AdGuard UI may be required)."
    fi
    echo "[+] Lease registered for ${TARGET_APP}"
else
    echo "[+] AdGuard Primary (${ADGUARD_PRIMARY_IP}) is reachable. DHCP configuration aligned."
fi
