#!/usr/bin/env bash
# ==============================================================================
# Dual-Node Active-Active AdGuard Home & adguardhome-sync Automated Installer
# CT 501 (Primary on proxmox)
# CT 502 (Secondary on tuxmox)
# ==============================================================================
set -euo pipefail

# Load secrets if present in repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd || echo "")"
if [ -n "${REPO_ROOT}" ] && [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

PRIMARY_IP="${PRIMARY_IP:-${ADGUARD_PRIMARY_IP:-10.0.0.201}}"
SECONDARY_IP="${SECONDARY_IP:-${ADGUARD_SECONDARY_IP:-10.0.0.202}}"
GATEWAY_IP="${GATEWAY_IP:-${DEFAULT_GATEWAY_IP:-10.0.0.1}}"
SUBNET_MASK="${SUBNET_MASK:-255.255.255.0}"
UPSTREAM_DNS_IP="${UPSTREAM_DNS_IP:-}"
LEGACY_VM100_IP="${LEGACY_VM100_IP:-${UPSTREAM_DNS_IP}}"

ADMIN_USER="${ADMIN_USER:-${ADGUARD_ADMIN_USER:-admin}}"
ADMIN_HASH="${ADGUARD_ADMIN_HASH:-}"
SYNC_USER="${SYNC_USER:-${ADGUARD_SYNC_USER:-sync}}"
SYNC_PASS="${ADGUARD_SYNC_PASS:-}"
SYNC_HASH="${ADGUARD_SYNC_HASH:-}"

# Parse subnet prefix for reverse PTR and DHCP pool calculations
IFS='.' read -r o1 o2 o3 _ <<< "${PRIMARY_IP}"
REVERSE_ARPA="${o3}.${o2}.${o1}.in-addr.arpa"
DHCP_RANGE_START="${DHCP_RANGE_START:-${o1}.${o2}.${o3}.100}"
DHCP_RANGE_END="${DHCP_RANGE_END:-${o1}.${o2}.${o3}.250}"

if [ -z "${ADMIN_HASH}" ] || [ -z "${SYNC_PASS}" ] || [ -z "${SYNC_HASH}" ]; then
    echo "[-] Error: ADGUARD_ADMIN_HASH, ADGUARD_SYNC_PASS, and ADGUARD_SYNC_HASH must be defined in environment or homelab-secrets.env." >&2
    exit 1
fi

echo "=============================================================================="
echo "    Deploying AdGuard Home Dual-Node HA DNS & DHCP Cluster                    "
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Fetch legacy configuration and leases from VM 100 if configured
# ------------------------------------------------------------------------------
TMP_DIR=$(mktemp -d /tmp/adguard-setup-XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT
echo "{}" > "${TMP_DIR}/leases.json"

if [ -n "${LEGACY_VM100_IP}" ]; then
    echo "[*] Checking for live AdGuard leases and config from legacy host (${LEGACY_VM100_IP})..."
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "root@${LEGACY_VM100_IP}" \
        "cat /opt/AdGuardHome/data/leases.json 2>/dev/null || cat /opt/adguardhome/data/leases.json 2>/dev/null || cat /var/lib/adguardhome/leases.json 2>/dev/null" > "${TMP_DIR}/leases.json" 2>/dev/null || true
    echo "[+] Leases captured ($(wc -c < "${TMP_DIR}/leases.json") bytes)"
fi

# ------------------------------------------------------------------------------
# Function: Generate AdGuardHome.yaml
# ------------------------------------------------------------------------------
generate_config() {
    local target_role="$1" # "primary" or "secondary"
    local dhcp_enabled="true"
    if [ "${target_role}" = "secondary" ]; then
        dhcp_enabled="false"
    fi

    cat <<EOF
http:
  pprof:
    port: 6060
    enabled: false
  doh:
    routes:
      - GET /dns-query
      - POST /dns-query
      - GET /dns-query/{ClientID}
      - POST /dns-query/{ClientID}
    insecure_enabled: false
  address: 0.0.0.0:3000
  session_ttl: 30d
users:
  - name: ${ADMIN_USER}
    password: ${ADMIN_HASH}
  - name: ${SYNC_USER}
    password: ${SYNC_HASH}
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - https://dns10.quad9.net/dns-query
    - "[/lan/]${PRIMARY_IP}"
    - "[/${REVERSE_ARPA}/]${PRIMARY_IP}"
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.10
    - 149.112.112.10
    - 2620:fe::10
    - 2620:fe::fe:10
  fallback_dns: []
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_enabled: true
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  cache_optimistic_answer_ttl: 30s
  cache_optimistic_max_age: 12h
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: ""
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: false
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
  pending_requests:
    enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 90d
  size_memory: 1000
  enabled: true
  ignored_enabled: false
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 1d
  enabled: true
  ignored_enabled: false
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: false
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
whitelist_filters: []
user_rules: []
dhcp:
  enabled: ${dhcp_enabled}
  interface_name: eth0
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ${GATEWAY_IP}
    subnet_mask: ${SUBNET_MASK}
    range_start: ${DHCP_RANGE_START}
    range_end: ${DHCP_RANGE_END}
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options:
      - "6 ip ${PRIMARY_IP}, ${SECONDARY_IP}"
  dhcpv6:
    range_start: 2001::1
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: UTC
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites: []
  safe_fs_patterns:
    - /opt/AdGuardHome/data/userfilters/*
  max_http_size: 256MB
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  rewrites_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 34
EOF
}

# ------------------------------------------------------------------------------
# Function: Install AdGuard Home on a target node
# ------------------------------------------------------------------------------
setup_adguard_node() {
    local target_ip="$1"
    local target_role="$2" # "primary" or "secondary"

    echo "------------------------------------------------------------------------------"
    echo "[*] Setting up AdGuard Home on ${target_ip} (${target_role})..."
    echo "------------------------------------------------------------------------------"

    # Install prerequisites
    ssh -o StrictHostKeyChecking=no "root@${target_ip}" bash -s <<'REMOTECOMMANDS'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    wget \
    dnsutils \
    tar \
    jq \
    sudo \
    procps
REMOTECOMMANDS

    # Download official AdGuard Home binary
    echo "[*] Downloading official AdGuard Home binary on ${target_ip}..."
    ssh -o StrictHostKeyChecking=no "root@${target_ip}" bash -s <<'REMOTECOMMANDS'
mkdir -p /opt/AdGuardHome/data
curl -sSL -o /tmp/AdGuardHome_linux_amd64.tar.gz "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_amd64.tar.gz"
tar -xzf /tmp/AdGuardHome_linux_amd64.tar.gz -C /opt/
rm -f /tmp/AdGuardHome_linux_amd64.tar.gz
REMOTECOMMANDS

    # Push configuration & leases
    echo "[*] Injecting AdGuardHome configuration and static leases on ${target_ip}..."
    generate_config "${target_role}" > "${TMP_DIR}/AdGuardHome.yaml"
    scp -o StrictHostKeyChecking=no "${TMP_DIR}/AdGuardHome.yaml" "root@${target_ip}:/opt/AdGuardHome/AdGuardHome.yaml"
    scp -o StrictHostKeyChecking=no "${TMP_DIR}/leases.json" "root@${target_ip}:/opt/AdGuardHome/data/leases.json"
    ssh -o StrictHostKeyChecking=no "root@${target_ip}" "mkdir -p /opt/AdGuardHome/data/data && cp /opt/AdGuardHome/data/leases.json /opt/AdGuardHome/data/data/leases.json"

    # Install & enable systemd service
    echo "[*] Installing and starting systemd service on ${target_ip}..."
    ssh -o StrictHostKeyChecking=no "root@${target_ip}" bash -s <<'REMOTECOMMANDS'
if [ -f /etc/systemd/system/AdGuardHome.service ]; then
    systemctl stop AdGuardHome 2>/dev/null || true
    /opt/AdGuardHome/AdGuardHome -s uninstall 2>/dev/null || true
fi

/opt/AdGuardHome/AdGuardHome -s install -c /opt/AdGuardHome/AdGuardHome.yaml -w /opt/AdGuardHome/data
systemctl daemon-reload
systemctl enable AdGuardHome
systemctl restart AdGuardHome
sleep 3
systemctl is-active --quiet AdGuardHome && echo "[+] AdGuardHome service is active on $(hostname)."
REMOTECOMMANDS
}

# ------------------------------------------------------------------------------
# 2. Setup CT 501 (Primary) and CT 502 (Secondary)
# ------------------------------------------------------------------------------
setup_adguard_node "${PRIMARY_IP}" "primary"
setup_adguard_node "${SECONDARY_IP}" "secondary"

# ------------------------------------------------------------------------------
# 3. Setup adguardhome-sync on CT 501 (Primary)
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------------------"
echo "[*] Installing adguardhome-sync on CT 501 (Primary)..."
echo "------------------------------------------------------------------------------"

# Download binary and configure systemd service
ssh -o StrictHostKeyChecking=no "root@${PRIMARY_IP}" bash -s <<'REMOTECOMMANDS'
set -euo pipefail

# Download adguardhome-sync v0.9.2
SYNC_VER="v0.9.2"
curl -sSL -o /tmp/agh-sync.tar.gz "https://github.com/bakito/adguardhome-sync/releases/download/${SYNC_VER}/adguardhome-sync_${SYNC_VER#v}_linux_amd64.tar.gz"
tar -xzf /tmp/agh-sync.tar.gz -C /tmp adguardhome-sync
install -m 755 /tmp/adguardhome-sync /usr/local/bin/adguardhome-sync
rm -f /tmp/agh-sync.tar.gz /tmp/adguardhome-sync
mkdir -p /etc/adguardhome-sync
REMOTECOMMANDS

# Inject sync config
cat <<SYNCCONFIG > "${TMP_DIR}/adguardhome-sync.yaml"
cron: "*/5 * * * *"
runOnStart: true
continueOnError: true

origin:
  url: "http://127.0.0.1:3000"
  username: "${SYNC_USER}"
  password: "${SYNC_PASS}"

replica:
  url: "http://${SECONDARY_IP}:3000"
  username: "${SYNC_USER}"
  password: "${SYNC_PASS}"

api:
  port: 8080

features:
  dns:
    accessLists: true
    serverConfig: true
    rewrites: true
  dhcp:
    serverConfig: false
    staticLeases: true
  generalSettings: true
  protectionStatus: false
  queryLogConfig: true
  statsConfig: true
  clientSettings: true
  services: true
  filters:
    blacklist: true
    whitelist: true
    userRules: true
  theme: true
  tlsConfig: false
SYNCCONFIG

scp -o StrictHostKeyChecking=no "${TMP_DIR}/adguardhome-sync.yaml" "root@${PRIMARY_IP}:/etc/adguardhome-sync/adguardhome-sync.yaml"

ssh -o StrictHostKeyChecking=no "root@${PRIMARY_IP}" bash -s <<'REMOTECOMMANDS'
set -euo pipefail

cat <<'SYSTEMD' > /etc/systemd/system/adguardhome-sync.service
[Unit]
Description=AdGuard Home High Availability Sync Daemon
After=network.target AdGuardHome.service
Wants=AdGuardHome.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/adguardhome-sync run --config /etc/adguardhome-sync/adguardhome-sync.yaml
Restart=always
RestartSec=10
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
SYSTEMD

systemctl daemon-reload
systemctl enable adguardhome-sync
systemctl restart adguardhome-sync
sleep 3
systemctl is-active --quiet adguardhome-sync && echo "[+] adguardhome-sync service is active on primary."
REMOTECOMMANDS

# ------------------------------------------------------------------------------
# 4. Inject Authoritative Static DHCP Leases
# ------------------------------------------------------------------------------
if [ -f "${REPO_ROOT}/scripts/configure-adguard-dhcp.sh" ]; then
    echo "[*] Injecting authoritative homelab static DHCP leases..."
    "${REPO_ROOT}/scripts/configure-adguard-dhcp.sh"
fi

echo "=============================================================================="
echo "    AdGuard Home Dual-Node HA Deployment Completed Successfully!             "
echo "=============================================================================="
