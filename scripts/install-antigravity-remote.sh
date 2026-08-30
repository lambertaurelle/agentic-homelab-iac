#!/usr/bin/env bash
# ==============================================================================
# Antigravity 2.0 Remote Control Service Installer & Lifecycle Manager
# Target: Management Workspace (CT 900 mgmt-devops on proxmox)
# ==============================================================================
# Can be executed:
#   1. Directly inside CT 900 -> Sets up systemd --user service and wrapper
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
WRAPPER_DIR="${HOME}/.antigravity/bin"
WRAPPER_FILE="${WRAPPER_DIR}/run_agy_remote_control.sh"
LOG_DIR="${HOME}/.antigravity"
LOG_FILE="${LOG_DIR}/agy_daemon.log"
SERVICE_NAME="agy-remote-control.service"
SERVICE_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SERVICE_DIR}/${SERVICE_NAME}"
UPDATE_SERVICE_NAME="agy-remote-control-update.service"
UPDATE_TIMER_NAME="agy-remote-control-update.timer"
UPDATE_SERVICE_FILE="${SERVICE_DIR}/${UPDATE_SERVICE_NAME}"
UPDATE_TIMER_FILE="${SERVICE_DIR}/${UPDATE_TIMER_NAME}"
TOKEN_FILE="${HOME}/.gemini/jetski-standalone-oauth-token"
SOURCE_TOKEN_FILE="${HOME}/.gemini/antigravity-cli/antigravity-oauth-token"

# Parse CLI arguments
ACTION="install"
RC_NAME="${DEFAULT_NAME}"
AUTO_UPDATE=true
NO_PROMPT=false
UPDATE_INTERVAL="daily"

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
        --no-auto-update)
            AUTO_UPDATE=false
            shift
            ;;
        --auto-update)
            AUTO_UPDATE=true
            shift
            ;;
        --no-prompt)
            NO_PROMPT=true
            shift
            ;;
        --interval)
            UPDATE_INTERVAL="${2:-daily}"
            shift 2
            ;;
        --interval=*)
            UPDATE_INTERVAL="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [install|status|restart|logs|uninstall|logout] [OPTIONS]"
            echo ""
            echo "Commands:"
            echo "  install                  Install and start Antigravity 2.0 Remote Control service"
            echo "  status                   Check current status of the daemon and auto-update timer"
            echo "  restart                  Restart the remote control service"
            echo "  logs                     View live or recent service logs"
            echo "  logout                   Sign out and remove auth token"
            echo "  uninstall                Stop and remove service units and wrapper"
            echo ""
            echo "Options:"
            echo "  --name <name>            Instance name shown in Remote Control Dashboard (default: mgmt-devops)"
            echo "  --no-prompt              Do not prompt for name; use default or --name"
            echo "  --no-auto-update         Disable scheduled daily service restart for updates"
            echo "  --interval <cadence>     Update restart cadence (default: daily)"
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

    # Dispatch command to CT 900 via pct or SSH
    REMOTE_SCRIPT="/root/homelab-iac/scripts/install-antigravity-remote.sh"
    FLAGS=()
    [ "$NO_PROMPT" = true ] && FLAGS+=("--no-prompt")
    [ "$AUTO_UPDATE" = false ] && FLAGS+=("--no-auto-update")

    CMD="${REMOTE_SCRIPT} ${ACTION} --name ${RC_NAME} ${FLAGS[*]} --interval ${UPDATE_INTERVAL}"

    if command -v pct >/dev/null 2>&1; then
        pct exec "${CT_ID}" -- bash -c "${CMD}"
    else
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${PROXMOX_HOST}" "pct exec ${CT_ID} -- bash -c '${CMD}'"
    fi
    exit 0
fi

# ------------------------------------------------------------------------------
# Local Execution (Inside CT 900)
# ------------------------------------------------------------------------------
echo "=============================================================================="
echo "    Antigravity 2.0 Remote Control Service Manager (CT 900)                  "
echo "=============================================================================="

# Helper: Ensure XDG and User Environment
ensure_environment() {
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
    export PATH="${HOME}/.local/bin:${PATH}"

    if command -v loginctl >/dev/null 2>&1; then
        loginctl enable-linger "$(whoami)" 2>/dev/null || true
    fi
}

# Helper: Ensure agy binary exists and is up to date
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

    echo "[*] Ensuring latest version of Antigravity CLI..."
    "$AGY_BIN" update || true
}

# Helper: Link or verify authentication token
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
        echo "    If this is the first run in a headless environment, you will be prompted to authenticate."
    fi
}

# Helper: Write launcher wrapper script
write_launcher_wrapper() {
    mkdir -p "$WRAPPER_DIR" "$LOG_DIR"

    cat << "EOF_WRAPPER" > "$WRAPPER_FILE"
#!/usr/bin/env bash
# ==============================================================================
# Antigravity 2.0 Remote Control Launcher Wrapper
# ==============================================================================
set -euo pipefail

export PATH="${HOME}/.local/bin:${PATH}"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

AGY_BIN="${HOME}/.local/bin/agy"
[[ -x "$AGY_BIN" ]] || AGY_BIN=$(command -v agy)

# Dynamic loopback port selection (probe 4400-4500)
PORT=4400
while (( PORT < 4500 )) && (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; do
    PORT=$((PORT + 1))
done

exec "$AGY_BIN" --remote-control --hub-port "$PORT" --remote-control-name "__RC_NAME__" "$@"
EOF_WRAPPER

    sed -i "s/__RC_NAME__/${RC_NAME}/g" "$WRAPPER_FILE"
    chmod +x "$WRAPPER_FILE"
    echo "[+] Created daemon launcher wrapper at: ${WRAPPER_FILE}"
    echo "    Configured Remote Control instance name: ${RC_NAME}"
}

# Helper: Install systemd user unit and timer
install_systemd_units() {
    mkdir -p "$SERVICE_DIR"

    cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Antigravity 2.0 Remote Control Service Daemon
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Environment=AGY_CLI_DISABLE_AUTO_UPDATE=false
Environment=XDG_RUNTIME_DIR=/run/user/0
Environment=PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStartPre=-${AGY_BIN} --bg-updater
ExecStart=${WRAPPER_FILE}
Restart=always
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}

[Install]
WantedBy=default.target
EOF_SERVICE

    echo "[+] Created systemd user service unit at: ${SERVICE_FILE}"

    # Auto-update timer
    if [ "$AUTO_UPDATE" = true ]; then
        cat << EOF_UPDATE_SVC > "$UPDATE_SERVICE_FILE"
[Unit]
Description=Restart Antigravity 2.0 Remote Control Daemon to apply updates

[Service]
Type=oneshot
ExecStart=$(command -v systemctl) --user restart ${SERVICE_NAME}
EOF_UPDATE_SVC

        cat << EOF_UPDATE_TIMER > "$UPDATE_TIMER_FILE"
[Unit]
Description=Daily restart of Antigravity 2.0 Remote Control Daemon for updates

[Timer]
OnCalendar=${UPDATE_INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
EOF_UPDATE_TIMER

        echo "[+] Created auto-update timer at: ${UPDATE_TIMER_FILE} (${UPDATE_INTERVAL})"
    else
        rm -f "$UPDATE_SERVICE_FILE" "$UPDATE_TIMER_FILE"
    fi

    # Reload and enable
    systemctl --user daemon-reload
    systemctl --user enable "${SERVICE_NAME}"
    if [ "$AUTO_UPDATE" = true ]; then
        systemctl --user enable "${UPDATE_TIMER_NAME}"
        systemctl --user restart "${UPDATE_TIMER_NAME}"
    fi

    systemctl --user restart "${SERVICE_NAME}"
    echo "[+] Started and enabled ${SERVICE_NAME}"
}

# ------------------------------------------------------------------------------
# Action Handlers
# ------------------------------------------------------------------------------
do_install() {
    ensure_environment
    ensure_agy_binary
    ensure_auth_token
    write_launcher_wrapper
    install_systemd_units

    sleep 2
    if systemctl --user is-active --quiet "${SERVICE_NAME}"; then
        echo "=============================================================================="
        echo "🎉 SUCCESS: Antigravity 2.0 Remote Control Daemon is ACTIVE!"
        echo "=============================================================================="
        echo "• Service Unit:   ${SERVICE_NAME}"
        echo "• Instance Name:  ${RC_NAME}"
        echo "• Log Output:     ${LOG_FILE}"
        echo "• Dashboard URL:  https://antigravity.google"
        echo "=============================================================================="
    else
        echo "[!] Warning: Daemon did not report active immediately. Recent logs:"
        tail -n 20 "${LOG_FILE}" 2>/dev/null || true
    fi
}

do_status() {
    ensure_environment
    echo "--- Service Status (${SERVICE_NAME}) ---"
    systemctl --user --no-pager status "${SERVICE_NAME}" || true

    if [ -f "$UPDATE_TIMER_FILE" ]; then
        echo ""
        echo "--- Auto-Update Timer Status ---"
        systemctl --user --no-pager list-timers "${UPDATE_TIMER_NAME}" || true
    fi

    echo ""
    echo "--- Recent Activity Logs (${LOG_FILE}) ---"
    tail -n 15 "${LOG_FILE}" 2>/dev/null || echo "No logs found."
}

do_restart() {
    ensure_environment
    systemctl --user restart "${SERVICE_NAME}"
    echo "[+] Successfully restarted ${SERVICE_NAME}"
    sleep 1
    systemctl --user --no-pager status "${SERVICE_NAME}" || true
}

do_logs() {
    if [ -f "${LOG_FILE}" ]; then
        tail -f "${LOG_FILE}"
    else
        echo "[-] Log file ${LOG_FILE} does not exist yet."
    fi
}

do_logout() {
    ensure_environment
    systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
    rm -f "${TOKEN_FILE}"
    echo "[+] Stopped service and cleared authentication token (${TOKEN_FILE})."
}

do_uninstall() {
    ensure_environment
    systemctl --user stop "${SERVICE_NAME}" 2>/dev/null || true
    systemctl --user disable "${SERVICE_NAME}" 2>/dev/null || true
    systemctl --user stop "${UPDATE_TIMER_NAME}" 2>/dev/null || true
    systemctl --user disable "${UPDATE_TIMER_NAME}" 2>/dev/null || true
    rm -f "${SERVICE_FILE}" "${WRAPPER_FILE}" "${UPDATE_SERVICE_FILE}" "${UPDATE_TIMER_FILE}"
    systemctl --user daemon-reload
    echo "[+] Successfully uninstalled Antigravity 2.0 Remote Control service and unit files."
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
