#!/usr/bin/env bash
# ==============================================================================
# Homelab Workload & Application Container Scaffolder
# ==============================================================================
# Interactively or declaratively scaffolds a new workload container on Proxmox:
#   1. Mode: Custom In-House App (with Instant CD via Watchtower HTTP API)
#   2. Mode: Third-Party Stack (Standard Docker Compose + Nightly Updates)
#   3. Mode: Native Service (Debian Bare-Metal Package)
#
# Usage:
#   ./scripts/scaffold-app.sh                                  # Interactive mode
#   ./scripts/scaffold-app.sh --type custom --name my-app      # Automated mode
#   ./scripts/scaffold-app.sh --dry-run --name test-app        # Dry-run validation
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Default values
WORKLOAD_TYPE=""
APP_NAME=""
TARGET_NODE="node-2"
APP_REPO=""
APP_PORT="8080"
APP_MEMORY=2048
APP_CORES=2
APP_DISK=20
APP_CTID=""
APP_IP="dhcp"
DRY_RUN=false
INTERACTIVE=true

# Parse CLI flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        --type|-t)
            WORKLOAD_TYPE="$2"
            INTERACTIVE=false
            shift 2
            ;;
        --name|-n)
            APP_NAME="$2"
            shift 2
            ;;
        --node)
            TARGET_NODE="$2"
            shift 2
            ;;
        --repo|-r)
            APP_REPO="$2"
            shift 2
            ;;
        --port|-p)
            APP_PORT="$2"
            shift 2
            ;;
        --memory|-m)
            APP_MEMORY="$2"
            shift 2
            ;;
        --cores|-c)
            APP_CORES="$2"
            shift 2
            ;;
        --disk|-d)
            APP_DISK="$2"
            shift 2
            ;;
        --ctid)
            APP_CTID="$2"
            shift 2
            ;;
        --ip)
            APP_IP="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --non-interactive|-y)
            INTERACTIVE=false
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --type <custom|thirdparty|native>   Workload archetype (required)"
            echo "  --name <app-name>                   Application name (alphanumeric, lowercase)"
            echo "  --node <node-1|node-2>              Target Proxmox node (default: node-2)"
            echo "  --repo <org/repo>                   GitHub repo for custom app (e.g. youruser/myapp)"
            echo "  --port <container-port>             Internal application port (default: 8080)"
            echo "  --memory <mb>                       RAM in MB (default: 2048)"
            echo "  --cores <count>                     CPU cores (default: 2)"
            echo "  --disk <gb>                         Disk size in GB (default: 20)"
            echo "  --ctid <id>                         Explicit CT ID (default: auto-allocated 700+)"
            echo "  --ip <ip/cidr|dhcp>                 Static IPv4 with CIDR or 'dhcp' (default: dhcp)"
            echo "  --dry-run                           Simulate file creation without writing to disk"
            echo "  --non-interactive                   Run non-interactively with provided flags"
            echo "  -h, --help                          Show this help message"
            exit 0
            ;;
        *)
            echo "[-] Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# Interactive mode prompts
if [ "$INTERACTIVE" = true ]; then
    echo "=============================================================================="
    echo "    Proxmox VE Declarative Workload Scaffolder                                "
    echo "=============================================================================="
    echo ""

    if [ -z "$WORKLOAD_TYPE" ]; then
        echo "Select Workload Archetype:"
        echo "  1) Custom In-House App (Docker Compose + Watchtower Instant CD)"
        echo "  2) Third-Party Stack   (Docker Compose + Scheduled Daily Updates)"
        echo "  3) Native Bare-Metal   (Standalone Debian Service / APT Packages)"
        read -r -p "Enter choice [1-3]: " type_choice
        case "$type_choice" in
            1) WORKLOAD_TYPE="custom" ;;
            2) WORKLOAD_TYPE="thirdparty" ;;
            3) WORKLOAD_TYPE="native" ;;
            *) echo "[-] Invalid selection."; exit 1 ;;
        esac
    fi

    if [ -z "$APP_NAME" ]; then
        read -r -p "Enter application name (e.g. my-service): " APP_NAME
    fi

    read -r -p "Target Proxmox node [node-1/node-2] (default: node-2): " node_choice
    TARGET_NODE="${node_choice:-${TARGET_NODE}}"

    if [ -z "${APP_NAME}" ]; then
        echo "[-] Error: Application name is required." >&2
        exit 1
    fi

    if [ "${WORKLOAD_TYPE}" = "custom" ] && [ -z "${APP_REPO}" ]; then
        read -r -p "GitHub repo slug or container image (e.g. lambertaurelle/${APP_NAME}): " APP_REPO
    fi

    read -r -p "Target Proxmox node [node-2/node-1] (default: node-2): " node_choice
    TARGET_NODE="${node_choice:-${TARGET_NODE}}"

    read -r -p "Primary application port (default: ${APP_PORT}): " port_choice
    APP_PORT="${port_choice:-${APP_PORT}}"
fi

# Normalize application name (lowercase alphanumeric with hyphens)
APP_NAME=$(echo "${APP_NAME:-app}" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | sed -E 's/[^a-z0-9\-]//g')
APP_IDENTIFIER=$(echo "${APP_NAME}" | tr '-' '_')
WORKLOAD_TYPE="${WORKLOAD_TYPE:-custom}"
APP_REPO="${APP_REPO:-lambertaurelle/${APP_NAME}}"

# ------------------------------------------------------------------------------
# 2. Auto-Detect Next Available CTID & MAC
# ------------------------------------------------------------------------------
if [ -z "${APP_CTID}" ]; then
    USED_IDS=$(grep -rohE 'vm_id\s*=\s*[0-9]+' "${REPO_ROOT}/tofu/" 2>/dev/null | awk '{print $NF}' | sort -n || true)

    # Custom apps start in 700 range (e.g. 701, 702...)
    CANDIDATE=701
    while echo "${USED_IDS}" | grep -q "^${CANDIDATE}$"; do
        CANDIDATE=$((CANDIDATE + 1))
    done
    APP_CTID="${CANDIDATE}"
fi

# Deterministic MAC allocation (e.g., CT 702 -> bc:24:11:00:07:02)
MAC_SUFFIX=$(printf "%04d" "${APP_CTID}")
MAC_B4="${MAC_SUFFIX:0:2}"
MAC_B5="${MAC_SUFFIX:2:2}"
APP_MAC="bc:24:11:00:${MAC_B4}:${MAC_B5}"

WATCHTOWER_TOKEN=$(openssl rand -hex 16 2>/dev/null || echo "wt_token_${APP_NAME}_$(date +%s)")

echo "[+] Workload: ${APP_NAME} (${WORKLOAD_TYPE})"
echo "[+] Node:     ${TARGET_NODE}"
echo "[+] CTID:     ${APP_CTID}"
echo "[+] MAC:      ${APP_MAC}"
echo "[+] Memory:   ${APP_MEMORY} MB | Cores: ${APP_CORES} | Disk: ${APP_DISK} GB"

# ------------------------------------------------------------------------------
# 3. Generate OpenTofu Resource (tofu/ct-<app>.tf)
# ------------------------------------------------------------------------------
TOFU_FILE="${REPO_ROOT}/tofu/ct-${APP_NAME}.tf"
TOFU_CONTENT=$(cat <<TOFU_EOF
# ==============================================================================
# ${APP_NAME} LXC Container
# Workload Type: ${WORKLOAD_TYPE}
# Target Node: ${TARGET_NODE}
# ==============================================================================

module "ct_${APP_IDENTIFIER}" {
  source = "./modules/app-container"

  node_name   = "${TARGET_NODE}"
  vm_id       = ${APP_CTID}
  hostname    = "${APP_NAME}"
  description = "Managed by OpenTofu | ${APP_NAME} (${WORKLOAD_TYPE})"

  cores        = ${APP_CORES}
  memory       = ${APP_MEMORY}
  swap         = 512
  disk_size    = ${APP_DISK}
  disk_storage = "local-lvm"

  mac_address  = "${APP_MAC}"
  ipv4_address = "${APP_IP}"

  ssh_public_keys = var.app_ssh_public_keys
}
TOFU_EOF
)

# ------------------------------------------------------------------------------
# 4. Generate Docker Compose Stack & Workflows
# ------------------------------------------------------------------------------
if [ -d "${REPO_ROOT}/stacks/instance" ]; then
    STACK_DIR="${REPO_ROOT}/stacks/instance/${APP_NAME}"
else
    STACK_DIR="${REPO_ROOT}/stacks/${APP_NAME}"
fi
COMPOSE_FILE="${STACK_DIR}/docker-compose.yml"
ENV_FILE="${STACK_DIR}/.env.example"
SNIPPET_FILE="${STACK_DIR}/github-deploy-workflow.yml.snippet"

if [ "${WORKLOAD_TYPE}" = "custom" ]; then
    COMPOSE_CONTENT=$(cat <<COMPOSE_EOF
services:
  app:
    image: ghcr.io/${APP_REPO}:\${IMAGE_TAG:-latest}
    container_name: ${APP_NAME}
    restart: unless-stopped
    ports:
      - "${APP_PORT}:${APP_PORT}"
    environment:
      - PORT=${APP_PORT}
      - NODE_ENV=production
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  # Lightweight Instant Deployment Receiver (Pulls and restarts on push-to-main)
  watchtower:
    image: containrrr/watchtower:latest
    container_name: ${APP_NAME}-watchtower
    restart: unless-stopped
    command: --http-api-update --http-api-token "\${WATCHTOWER_HTTP_API_TOKEN}" --interval 86400 --label-enable
    environment:
      - WATCHTOWER_HTTP_API_TOKEN=\${WATCHTOWER_HTTP_API_TOKEN}
      - DOCKER_API_VERSION=1.45
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /root/.docker/config.json:/config.json:ro
    ports:
      - "8081:8080"
COMPOSE_EOF
)

    ENV_CONTENT=$(cat <<ENV_EOF
# Environment variables for ${APP_NAME}
PORT=${APP_PORT}
IMAGE_TAG=latest
WATCHTOWER_HTTP_API_TOKEN=${WATCHTOWER_TOKEN}
ENV_EOF
)

    SNIPPET_CONTENT=$(cat <<SNIPPET_EOF
# ==============================================================================
# GitHub Actions Continuous Deployment Workflow for ${APP_NAME}
# Place this file in .github/workflows/deploy.yml in repository: ${APP_REPO}
# ==============================================================================
name: "Build & Deploy to Homelab"

on:
  push:
    branches: [ main ]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: \${{ github.actor }}
          password: \${{ secrets.GITHUB_TOKEN }}
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ghcr.io/${APP_REPO}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  trigger-homelab-deployment:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Instant Watchtower Container Reload
        run: |
          echo "[*] Triggering container update on homelab..."
          # Configure secrets.HOMELAB_APP_HOST (e.g. 10.0.0.x or domain) and secrets.WATCHTOWER_TOKEN
          curl -f -sS -X POST \\
               -H "Authorization: Bearer \${{ secrets.WATCHTOWER_TOKEN }}" \\
               "http://\${{ secrets.HOMELAB_APP_HOST }}:8080/v1/update"
          echo "[+] Deployment triggered successfully!"
SNIPPET_EOF
)

elif [ "${WORKLOAD_TYPE}" = "thirdparty" ]; then
    COMPOSE_CONTENT=$(cat <<COMPOSE_EOF
services:
  ${APP_NAME}:
    image: ${APP_REPO}:latest
    container_name: ${APP_NAME}
    restart: unless-stopped
    ports:
      - "${APP_PORT}:${APP_PORT}"
    environment:
      - TZ=Europe/Paris
    volumes:
      - /opt/${APP_NAME}/data:/config
COMPOSE_EOF
)
    ENV_CONTENT=$(cat <<ENV_EOF
# Environment variables for ${APP_NAME}
TZ=Europe/Paris
ENV_EOF
)
    SNIPPET_CONTENT="# Third-party stack: automatically updated via scripts/update-cluster-stack.sh (daily 05:00 AM)"
else
    # Native bare-metal service
    COMPOSE_CONTENT="# Native service running directly on host without Docker"
    ENV_CONTENT="# Native environment variables"
    SNIPPET_CONTENT="# Native bare-metal package"
fi

# ------------------------------------------------------------------------------
# 5. Output / File Creation
# ------------------------------------------------------------------------------
if [ "${DRY_RUN}" = true ]; then
    echo ""
    echo "--- [DRY RUN] Generated ${TOFU_FILE} ---"
    echo "${TOFU_CONTENT}"
    echo ""
    echo "--- [DRY RUN] Generated ${COMPOSE_FILE} ---"
    echo "${COMPOSE_CONTENT}"
    echo ""
    echo "--- [DRY RUN] Generated ${ENV_FILE} ---"
    echo "${ENV_CONTENT}"
    if [ "${WORKLOAD_TYPE}" = "custom" ]; then
        echo ""
        echo "--- [DRY RUN] Generated ${SNIPPET_FILE} ---"
        echo "${SNIPPET_CONTENT}"
    fi
    echo "=============================================================================="
    echo "[+] Dry-run completed successfully with 0 errors!"
    exit 0
fi

# Write files to disk
mkdir -p "${STACK_DIR}"
echo "${TOFU_CONTENT}" > "${TOFU_FILE}"
echo "${COMPOSE_CONTENT}" > "${COMPOSE_FILE}"
echo "${ENV_CONTENT}" > "${ENV_FILE}"
if [ "${WORKLOAD_TYPE}" = "custom" ]; then
    echo "${SNIPPET_CONTENT}" > "${SNIPPET_FILE}"
fi

# Format OpenTofu HCL
if command -v tofu >/dev/null 2>&1; then
    tofu fmt "${TOFU_FILE}" >/dev/null 2>&1 || true
fi

echo "=============================================================================="
echo "[+] Successfully scaffolded workload: ${APP_NAME}!"
echo "=============================================================================="
echo "Created files:"
echo "  - OpenTofu Config:  tofu/ct-${APP_NAME}.tf"
echo "  - Docker Compose:   stacks/${APP_NAME}/docker-compose.yml"
echo "  - Environment:      stacks/${APP_NAME}/.env.example"
if [ "${WORKLOAD_TYPE}" = "custom" ]; then
    echo "  - CI/CD Snippet:    stacks/${APP_NAME}/github-deploy-workflow.yml.snippet"
fi
echo ""
echo "Next Steps:"
echo "  1. Review tofu plan:   cd tofu && tofu plan"
echo "  2. Provision LXC:      cd tofu && tofu apply -target=module.ct_${APP_IDENTIFIER}"
echo "  3. Bootstrap Docker:   pct exec ${APP_CTID} -- bash -c \"\$(curl -fsSL https://.../bootstrap-docker-host.sh)\""
