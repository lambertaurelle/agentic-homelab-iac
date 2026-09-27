#!/usr/bin/env bash
# ==============================================================================
# Antigravity 2.0 Remote Control Service Lifecycle Manager
# Target: Management Workspace (CT 900 mgmt-devops on proxmox)
# ==============================================================================
# Can be executed:
#   1. Directly inside CT 900 -> Manages native agy remote-control daemon
#   2. Remotely from Proxmox host -> Dispatches pct exec 900 to configure
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

PROXMOX_HOST="${PROXMOX_HOST:-${PROXMOX_NODE_IP:-10.0.0.10}}"
CT_ID="900"
CURRENT_HOSTNAME=$(hostname -s 2>/dev/null || hostname)

# Defaults & Paths
DEFAULT_NAME="mgmt-devops"
AGY_BIN="${HOME}/.local/bin/agy"
SERVICE_NAME="antigravity-cli-daemon.service"
LEGACY_SERVICE_NAME="agy-remote-control.service"
LEGACY_UPDATE_SERVICE="agy-remote-control-update.service"
LEGACY_UPDATE_TIMER="agy-remote-control-update.timer"
LEGACY_WRAPPER="${HOME}/.antigravity/bin/run_agy_remote_control.sh"
SERVICE_DIR="${HOME}/.config/systemd/user"
TOKEN_FILE="${HOME}/.gemini/jetski-standalone-oauth-token"
SOURCE_TOKEN_FILE="${HOME}/.gemini/antigravity-cli/antigravity-oauth-token"

# Parse CLI arguments
ACTION="install"
RC_NAME="${DEFAULT_NAME}"
FOLLOW_LOGS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        install|status|restart|logs|uninstall|logout)
            ACTION="$1"
            shift
            ;;
        --name)
            RC_NAME="${2:-${DEFAULT_NAME}}"
            shift 2
            ;;
        --name=*)
            RC_NAME="${1#*=}"
            shift
            ;;
        -f|--follow)
            FOLLOW_LOGS=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [install|status|restart|logs|uninstall|logout] [OPTIONS]"
            echo ""
            echo "Commands:"
            echo "  install                  Register and start native Antigravity Remote Control daemon"
            echo "  status                   Check current status of the daemon via agy and systemd"
            echo "  restart                  Restart the remote control service"
            echo "  logs                     View service logs via journalctl"
            echo "  logout                   Stop remote control daemon and remove auth token"
            echo "  uninstall                Stop daemon and clean up service registration"
            echo ""
            echo "Options:"
            echo "  --name <name>            Instance name shown in Remote Control Dashboard (default: mgmt-devops)"
            echo "  -f, --follow             Follow log output (for logs command)"
            exit 0
            ;;
        *)
            echo "[-] Unknown option: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Remote Dispatch if running outside CT 900
# ------------------------------------------------------------------------------
if [[ "${CURRENT_HOSTNAME}" != "mgmt-devops" ]]; then
    echo "=============================================================================="
    echo "    Antigravity 2.0 Remote Control Orchestrator (Remote Mode)                "
    echo "=============================================================================="
    echo "[*] Detected execution from host (${CURRENT_HOSTNAME})."
    echo "[*] Target container: CT ${CT_ID} (mgmt-devops) on ${PROXMOX_HOST}"

    REMOTE_SCRIPT="/root/homelab-iac/scripts/install-antigravity-remote.sh"
    FLAGS=()
    [ "$FOLLOW_LOGS" = true ] && FLAGS+=("-f")

    CMD="${REMOTE_SCRIPT} ${ACTION} --name ${RC_NAME} ${FLAGS[*]}"

    if command -v pct >/dev/null 2>&1; then
        pct exec "${CT_ID}" -- bash -c "${CMD}"
    else
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${PROXMOX_HOST}" "pct exec ${CT_ID} -- bash -c '${CMD}'"
    fi
    exit 0
fi

# ------------------------------------------------------------------------------
# Local Execution Helpers (Inside CT 900)
# ------------------------------------------------------------------------------
ensure_environment() {
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
    export PATH="${HOME}/.local/bin:${PATH}"

    if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$(whoami)" 2>/dev/null || true
    fi
}

ensure_agy_binary() {
    if [[ ! -x "$AGY_BIN" ]]; then
        AGY_BIN=$(command -v agy || true)
        if [[ -z "$AGY_BIN" ]]; then
            echo "[*] Antigravity CLI (agy) not found. Installing via official installer..."
            curl -fsSL https://antigravity.google/cli/install.sh | bash
            AGY_BIN="${HOME}/.local/bin/agy"
            [[ -x "$AGY_BIN" ]] || AGY_BIN=$(command -v agy || true)
            if [[ -z "$AGY_BIN" || ! -x "$AGY_BIN" ]]; then
                echo "[-] Fatal: Antigravity CLI installation failed." >&2
                exit 1
            fi
            echo "[+] Successfully installed agy at ${AGY_BIN}"
        fi
    fi

    echo "[*] Checking for Antigravity CLI updates..."
    "$AGY_BIN" update || true
}

ensure_auth_token() {
    mkdir -p "${HOME}/.gemini"
    if [[ ! -s "$TOKEN_FILE" ]] && [[ -s "$SOURCE_TOKEN_FILE" ]]; then
        echo "[*] Linking existing Antigravity OAuth credentials to ${TOKEN_FILE}..."
        cp "$SOURCE_TOKEN_FILE" "$TOKEN_FILE" 2>/dev/null || ln -sf "$SOURCE_TOKEN_FILE" "$TOKEN_FILE"
        chmod 600 "$TOKEN_FILE"
    fi

    if [[ -s "$TOKEN_FILE" ]]; then
        echo "[+] Active authentication token detected."
    else
        echo "[!] Notice: No existing OAuth token found at ${TOKEN_FILE}."
        echo "    If this is the first run in a headless environment, authenticate via agy."
    fi
}

cleanup_legacy_artifacts() {
    local modified=false

    for unit in "$LEGACY_SERVICE_NAME" "$LEGACY_UPDATE_SERVICE" "$LEGACY_UPDATE_TIMER"; do
        if systemctl --user is-active --quiet "$unit" 2>/dev/null; then
            echo "[*] Stopping legacy systemd unit: ${unit}"
            systemctl --user stop "$unit" 2>/dev/null || true
            systemctl --user disable "$unit" 2>/dev/null || true
            modified=true
        fi
        if [ -f "${SERVICE_DIR}/${unit}" ]; then
            echo "[*] Removing legacy unit file: ${SERVICE_DIR}/${unit}"
            rm -f "${SERVICE_DIR}/${unit}"
            modified=true
        fi
    done

    if [ -f "$LEGACY_WRAPPER" ]; then
        echo "[*] Removing deprecated launcher wrapper: ${LEGACY_WRAPPER}"
        rm -f "$LEGACY_WRAPPER"
    fi

    if [ "$modified" = true ]; then
        systemctl --user daemon-reload
    fi
}

# ------------------------------------------------------------------------------
# Action Handlers
# ------------------------------------------------------------------------------
do_install() {
    ensure_environment
    ensure_agy_binary
    ensure_auth_token
    cleanup_legacy_artifacts

    echo "[*] Registering and starting Antigravity Remote Control daemon with instance name: ${RC_NAME}..."
    "$AGY_BIN" remote-control start --name "${RC_NAME}"

    sleep 1
    echo "=============================================================================="
    echo "🎉 SUCCESS: Antigravity 2.0 Remote Control Daemon is registered!"
    echo "=============================================================================="
    "$AGY_BIN" remote-control status || true
    echo "=============================================================================="
}

do_status() {
    ensure_environment
    echo "--- Antigravity Remote Control Status ---"
    if [[ -x "$AGY_BIN" ]]; then
        "$AGY_BIN" remote-control status || true
    fi

    echo ""
    echo "--- Systemd Unit Status (${SERVICE_NAME}) ---"
    systemctl --user --no-pager status "${SERVICE_NAME}" || true
}

do_restart() {
    ensure_environment
    echo "[*] Restarting ${SERVICE_NAME}..."
    systemctl --user restart "${SERVICE_NAME}"
    sleep 1
    systemctl --user --no-pager status "${SERVICE_NAME}" || true
}

do_logs() {
    ensure_environment
    if [ "$FOLLOW_LOGS" = true ]; then
        journalctl --user -u "${SERVICE_NAME}" -f
    else
        journalctl --user -u "${SERVICE_NAME}" -n 50 --no-pager
    fi
}

do_logout() {
    ensure_environment
    echo "[*] Stopping Remote Control daemon..."
    if [[ -x "$AGY_BIN" ]]; then
        "$AGY_BIN" remote-control stop || true
    else
        systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
    fi
    rm -f "${TOKEN_FILE}"
    echo "[+] Stopped daemon and cleared authentication token (${TOKEN_FILE})."
}

do_uninstall() {
    ensure_environment
    cleanup_legacy_artifacts
    echo "[*] Stopping and unregistering Remote Control daemon..."
    if [[ -x "$AGY_BIN" ]]; then
        "$AGY_BIN" remote-control stop || true
    else
        systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
        systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
    fi
    echo "[+] Successfully uninstalled Antigravity Remote Control service."
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------
case "$ACTION" in
    install)   do_install ;;
    status)    do_status ;;
    restart)   do_restart ;;
    logs)      do_logs ;;
    logout)    do_logout ;;
    uninstall) do_uninstall ;;
    *)
        echo "[-] Error: Unknown action '${ACTION}'" >&2
        exit 1
        ;;
esac
