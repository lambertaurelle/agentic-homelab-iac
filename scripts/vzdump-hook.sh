#!/usr/bin/env bash
# ==============================================================================
# Proxmox VZDump Generic Hook Wrapper (scope: core)
# ==============================================================================
# Registered in /etc/vzdump.conf ('script: /root/homelab-iac/scripts/vzdump-hook.sh').
# Delegates cleanly to scripts/instance/vzdump-hook.sh if present.
# Always exits 0 so hook warnings never abort cluster backups.
# Note: PVE::VZDump clears %ENV before invoking hookscripts, so PATH is reset.
# ==============================================================================
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTANCE_HOOK="${SCRIPT_DIR}/instance/vzdump-hook.sh"

if [ -x "${INSTANCE_HOOK}" ]; then
    "${INSTANCE_HOOK}" "$@" || echo "[!] Warning: instance vzdump-hook returned non-zero ($?); continuing backup." >&2
fi

exit 0
