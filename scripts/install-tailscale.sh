#!/usr/bin/env bash
# ==============================================================================
# Tailscale Subnet Router & SSH Bastion Automated Installer
# Target: Debian 12 (Bookworm) Unprivileged LXC Container (CT 520 on node-1)
# Hostname: tailscale (or custom TAILSCALE_HOSTNAME)
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." 2>/dev/null && pwd || echo "")"

if [ -n "${REPO_ROOT}" ] && [ -f "${REPO_ROOT}/secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/secrets.env"
elif [ -n "${REPO_ROOT}" ] && [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

UTILITY_NODE_NAME="${UTILITY_NODE_NAME:-node-1}"
COMPUTE_NODE_NAME="${COMPUTE_NODE_NAME:-node-2}"
NODE1_IP="${NODE1_IP:-10.0.0.10}"
NODE2_IP="${NODE2_IP:-10.0.0.20}"
TARGET_NODE="${TARGET_NODE:-${UTILITY_NODE_NAME}}"
CT_ID="${TAILSCALE_CT_ID:-520}"
CONTAINER_HOSTNAME="${TAILSCALE_HOSTNAME:-tailscale}"
TS_ROUTES="${TAILSCALE_ROUTES:-${TS_ROUTES:-${LAN_SUBNET_CIDR:-10.0.0.0/24}}}"
TS_AUTHKEY="${TAILSCALE_AUTH_KEY:-${TS_AUTHKEY:-}}"

CURRENT_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
ACTION="install"
FORCE_LOCAL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        install|login|status)
            ACTION="$1"
            shift
            ;;
        --authkey)
            TS_AUTHKEY="${2:-}"
            shift 2
            ;;
        --routes)
            TS_ROUTES="${2:-${LAN_SUBNET_CIDR:-10.0.0.0/24}}"
            shift 2
            ;;
        --hostname)
            CONTAINER_HOSTNAME="${2:-tailscale}"
            shift 2
            ;;
        --ct-id)
            CT_ID="${2:-520}"
            shift 2
            ;;
        --node)
            TARGET_NODE="${2:-${UTILITY_NODE_NAME}}"
            shift 2
            ;;
        --local)
            FORCE_LOCAL=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [install|login|status] [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --authkey <key>      Tailscale auth key (optional; uses interactive URL if omitted)"
            echo "  --routes <cidr>      Subnet routes to advertise (default: LAN_SUBNET_CIDR / 10.0.0.0/24)"
            echo "  --hostname <name>    Tailnet hostname (default: tailscale)"
            echo "  --ct-id <id>         Target LXC CTID (default: 520)"
            echo "  --node <node>        Target Proxmox node (default: node-1)"
            echo "  --local              Force local execution inside container"
            exit 0
            ;;
        *)
            echo "[-] Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Target Node Discovery & Host-Level /dev/net/tun Provisioning
# ------------------------------------------------------------------------------
find_target_node() {
    local ctid="$1"
    if command -v pct >/dev/null 2>&1 && pct status "${ctid}" >/dev/null 2>&1; then
        echo "local"
        return 0
    fi

    local candidate_nodes=("${TARGET_NODE}" "${UTILITY_NODE_NAME}" "${NODE1_IP}" "${COMPUTE_NODE_NAME}" "${NODE2_IP}" "node-1" "node-2")
    for node in "${candidate_nodes[@]}"; do
        [ -z "${node}" ] && continue
        if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=3 "root@${node}" "pct status ${ctid}" >/dev/null 2>&1; then
            echo "${node}"
            return 0
        fi
    done
    return 1
}

run_on_host() {
    local target="$1"
    local cmd="$2"
    if [ "${target}" = "local" ]; then
        bash -c "${cmd}"
    else
        ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${target}" "${cmd}"
    fi
}

ensure_host_tun_passthrough() {
    local target="$1"
    local ctid="$2"
    local conf_path="/etc/pve/lxc/${ctid}.conf"

    echo "[*] Verifying /dev/net/tun passthrough in ${conf_path} on ${target}..."
    local needs_restart=false

    if ! run_on_host "${target}" "grep -Fq 'lxc.cgroup2.devices.allow: c 10:200 rwm' ${conf_path}"; then
        echo "[*] Adding lxc.cgroup2.devices.allow for /dev/net/tun to ${conf_path}..."
        run_on_host "${target}" "echo 'lxc.cgroup2.devices.allow: c 10:200 rwm' >> ${conf_path}"
        needs_restart=true
    fi

    if ! run_on_host "${target}" "grep -Fq 'lxc.mount.entry: /dev/net/tun' ${conf_path}"; then
        echo "[*] Adding lxc.mount.entry for /dev/net/tun to ${conf_path}..."
        run_on_host "${target}" "echo 'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >> ${conf_path}"
        needs_restart=true
    fi

    if [ "${needs_restart}" = true ]; then
        echo "[*] Restarting CT ${ctid} to activate /dev/net/tun device mount..."
        run_on_host "${target}" "pct stop ${ctid} 2>/dev/null || true; pct start ${ctid}"
        sleep 4
    else
        if ! run_on_host "${target}" "pct status ${ctid}" | grep -q "status: running"; then
            echo "[*] Starting CT ${ctid}..."
            run_on_host "${target}" "pct start ${ctid}"
            sleep 4
        fi
    fi

    echo "[+] Host /dev/net/tun passthrough verified for CT ${ctid}."
}

# ------------------------------------------------------------------------------
# Remote Dispatch Mode (When executed outside CT 520)
# ------------------------------------------------------------------------------
if [ "${FORCE_LOCAL}" = false ] && [[ "${CURRENT_HOSTNAME}" != "${CONTAINER_HOSTNAME}" ]]; then
    echo "=============================================================================="
    echo "    Tailscale Subnet Router Installer (Remote Orchestrator Dispatch Mode)     "
    echo "=============================================================================="
    echo "[*] Executing from: ${CURRENT_HOSTNAME}"

    TARGET_HOST=$(find_target_node "${CT_ID}") || {
        echo "[-] Error: Unable to locate cluster node hosting CT ${CT_ID}." >&2
        exit 1
    }

    echo "[*] Target Container: CT ${CT_ID} (${CONTAINER_HOSTNAME}) on node: ${TARGET_HOST}"
    ensure_host_tun_passthrough "${TARGET_HOST}" "${CT_ID}"

    LOCAL_SCRIPT="${SCRIPT_DIR}/install-tailscale.sh"
    REMOTE_SCRIPT="/tmp/install-tailscale.sh"

    FORWARD_ARGS=("${ACTION}" "--local" "--hostname" "${CONTAINER_HOSTNAME}" "--routes" "${TS_ROUTES}")
    if [ -n "${TS_AUTHKEY}" ]; then
        FORWARD_ARGS+=("--authkey" "${TS_AUTHKEY}")
    fi

    if [ "${TARGET_HOST}" = "local" ]; then
        pct push "${CT_ID}" "${LOCAL_SCRIPT}" "${REMOTE_SCRIPT}"
        pct exec "${CT_ID}" -- chmod +x "${REMOTE_SCRIPT}"
        pct exec "${CT_ID}" -- "${REMOTE_SCRIPT}" "${FORWARD_ARGS[@]}"
    else
        scp -q -o StrictHostKeyChecking=no "${LOCAL_SCRIPT}" "root@${TARGET_HOST}:/tmp/install-tailscale-host.sh"
        ssh -o StrictHostKeyChecking=no "root@${TARGET_HOST}" \
            "pct push ${CT_ID} /tmp/install-tailscale-host.sh ${REMOTE_SCRIPT} && \
             rm -f /tmp/install-tailscale-host.sh && \
             pct exec ${CT_ID} -- chmod +x ${REMOTE_SCRIPT} && \
             pct exec ${CT_ID} -- ${REMOTE_SCRIPT} ${FORWARD_ARGS[*]}"
    fi
    exit 0
fi

# ==============================================================================
# Local Execution Mode (Inside CT 520: tailscale)
# ==============================================================================
export DEBIAN_FRONTEND=noninteractive

do_status() {
    echo "=============================================================================="
    echo "    Tailscale Subnet Router Status (${CONTAINER_HOSTNAME})                    "
    echo "=============================================================================="
    echo "[*] Hostname:   $(hostname)"
    echo "[*] LAN IPv4:   $(hostname -I | awk '{print $1}')"
    echo "[*] TUN Device: $([ -c /dev/net/tun ] && echo 'PRESENT (/dev/net/tun)' || echo 'MISSING')"
    echo "[*] IPv4 Fwd:   $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 'unknown')"
    echo "[*] Daemon:     $(systemctl is-active tailscaled 2>/dev/null || echo 'inactive')"
    echo ""
    echo "--- Tailscale Status ---"
    tailscale status 2>&1 || true
    echo "=============================================================================="
}

do_login() {
    echo "[*] Authenticating Tailscale node '${CONTAINER_HOSTNAME}' (routes: ${TS_ROUTES})..."

    # Check if already logged in and online
    if tailscale status >/dev/null 2>&1; then
        echo "[+] Tailscale is already authenticated. Applying desired configuration..."
        tailscale set --advertise-routes="${TS_ROUTES}" --accept-dns=false --ssh
        do_status
        return 0
    fi

    if [ -n "${TS_AUTHKEY}" ]; then
        echo "[*] Registering headless node using provided TS_AUTHKEY..."
        tailscale up \
            --authkey="${TS_AUTHKEY}" \
            --hostname="${CONTAINER_HOSTNAME}" \
            --advertise-routes="${TS_ROUTES}" \
            --accept-dns=false \
            --ssh
        do_status
        return 0
    fi

    # Interactive browser login flow (non-blocking URL capture)
    echo "[*] Starting interactive Tailscale login session in background..."
    pkill -f "tailscale up" 2>/dev/null || true
    rm -f /tmp/tailscale-login.log

    nohup tailscale up \
        --hostname="${CONTAINER_HOSTNAME}" \
        --advertise-routes="${TS_ROUTES}" \
        --accept-dns=false \
        --ssh \
        --qr=false > /tmp/tailscale-login.log 2>&1 &

    local login_url=""
    for _ in $(seq 1 20); do
        if [ -f /tmp/tailscale-login.log ]; then
            login_url=$(grep -Eo 'https://login\.tailscale\.com/a/[a-zA-Z0-9]+' /tmp/tailscale-login.log | head -n1 || true)
            if [ -n "${login_url}" ]; then
                break
            fi
        fi
        if tailscale status >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    if [ -n "${login_url}" ]; then
        echo "=============================================================================="
        echo "  ACTION REQUIRED: Authorize '${CONTAINER_HOSTNAME}' in your browser:"
        echo "  --> ${login_url}"
        echo "=============================================================================="
        echo "  After authorizing, approve subnet route '${TS_ROUTES}' in Tailscale Admin Console."
    else
        echo "[!] Tailscale login output:"
        cat /tmp/tailscale-login.log 2>/dev/null || true
    fi
}

do_install() {
    echo "=============================================================================="
    echo "    Installing Tailscale Subnet Router (${CONTAINER_HOSTNAME})                "
    echo "=============================================================================="

    # 1. Verify /dev/net/tun inside container
    if [ ! -c /dev/net/tun ]; then
        echo "[*] Creating /dev/net/tun character device node..."
        mkdir -p /dev/net
        mknod /dev/net/tun c 10 200 || true
        chmod 0666 /dev/net/tun || true
    fi

    if [ ! -c /dev/net/tun ]; then
        echo "[-] Error: /dev/net/tun is not available inside container." >&2
        exit 1
    fi
    echo "[+] Verified /dev/net/tun character device is available."

    # 2. Wait for DHCP IP / network readiness
    for _ in $(seq 1 15); do
        if hostname -I | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
            break
        fi
        sleep 1
    done
    echo "[+] Container LAN IP: $(hostname -I | awk '{print $1}')"

    # 3. Install prerequisite packages
    echo "[*] Installing prerequisite packages..."
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        gpg \
        lsb-release \
        apt-transport-https \
        ethtool \
        networkd-dispatcher \
        iproute2 \
        iptables \
        procps \
        openssh-server

    # 4. Configure Kernel IPv4 & IPv6 Packet Forwarding
    echo "[*] Configuring /etc/sysctl.d/99-tailscale.conf for IP forwarding..."
    cat << 'EOF_SYSCTL' > /etc/sysctl.d/99-tailscale.conf
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF_SYSCTL
    sysctl -p /etc/sysctl.d/99-tailscale.conf

    # 5. Configure UDP GRO Forwarding Optimization for Linux 6.x Kernel
    echo "[*] Configuring UDP GRO forwarding optimization on eth0..."
    mkdir -p /etc/networkd-dispatcher/routable.d
    cat << 'EOF_GRO' > /etc/networkd-dispatcher/routable.d/50-tailscale
#!/bin/sh
/sbin/ethtool -K eth0 rx-udp-gro-forwarding on rx-gro-list off || true
EOF_GRO
    chmod 0755 /etc/networkd-dispatcher/routable.d/50-tailscale
    /etc/networkd-dispatcher/routable.d/50-tailscale || true

    # 6. Install Official Tailscale Debian 12 (Bookworm) Repository & Package
    echo "[*] Adding official Tailscale Debian 12 (Bookworm) repository..."
    mkdir -p /usr/share/keyrings
    chmod 0755 /usr/share/keyrings
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
        -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.tailscale-keyring.list \
        -o /etc/apt/sources.list.d/tailscale.list

    echo "[*] Installing tailscale package..."
    apt-get update -qq
    apt-get install -y -qq tailscale

    echo "[+] Installed Tailscale version: $(tailscale --version | head -n1)"

    # 7. Enable and start tailscaled service
    systemctl daemon-reload
    systemctl enable --now tailscaled
    systemctl enable --now ssh

    # 8. Authenticate / Start Tailscale Subnet Router
    do_login
}

case "${ACTION}" in
    install) do_install ;;
    login)   do_login ;;
    status)  do_status ;;
    *)
        echo "[-] Unknown action: ${ACTION}" >&2
        exit 1
        ;;
esac
