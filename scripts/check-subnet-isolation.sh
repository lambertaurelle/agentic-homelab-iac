#!/usr/bin/env bash
# ==============================================================================
# Bidirectional Subnet Isolation & Anti-Leak Validator
# ==============================================================================
# Enforces strict two-way network boundaries:
#   1. Instance Scope: NO upstream template IPs (10.0.0.x) allowed in private instance files.
#   2. Core Scope: NO private physical IPs (192.168.1.x) hardcoded in public core files.
#
# Exit codes:
#   0 - Clean boundaries
#   1 - Boundary violation detected
# ==============================================================================
set -euo pipefail
# shellcheck disable=SC2001

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0

print_indented_errors() {
    local text="$1"
    while IFS= read -r line; do
        [ -n "${line}" ] && echo "    ! ${line}" >&2
    done <<< "${text}"
}

echo "=============================================================================="
echo "    Bidirectional Subnet Isolation Guard (10.0.0.x <-> 192.168.1.x)          "
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Gate A: Ensure NO 10.0.0.x in Private Instance Scope
# ------------------------------------------------------------------------------
echo "[*] Checking Private Instance Scope (forbidding 10.0.0.x)..."

INSTANCE_PATHS=(
    "${REPO_ROOT}/stacks/instance"
    "${REPO_ROOT}/scripts/instance"
    "${REPO_ROOT}/docs/instance"
)

for p in "${INSTANCE_PATHS[@]}"; do
    if [ -d "${p}" ]; then
        # Exclude RFC1918 block matches like 10.0.0.0/8 in nftables rules
        MATCHES=$(grep -rnE "10\.0\.0\.[0-9]+" "${p}" 2>/dev/null | grep -v "10.0.0.0/8" || true)
        if [ -n "${MATCHES}" ]; then
            echo "[-] ERROR: Upstream template IP (10.0.0.x) found in private instance path '${p}':" >&2
            print_indented_errors "${MATCHES}"
            FAILED=1
        fi
    fi
done

for f in "${REPO_ROOT}/tofu"/instance-*.tf; do
    if [ -f "${f}" ]; then
        MATCHES=$(grep -rnE "10\.0\.0\.[0-9]+" "${f}" 2>/dev/null || true)
        if [ -n "${MATCHES}" ]; then
            echo "[-] ERROR: Upstream template IP (10.0.0.x) found in instance OpenTofu file '${f}':" >&2
            print_indented_errors "${MATCHES}"
            FAILED=1
        fi
    fi
done

for sec_file in "${REPO_ROOT}/homelab-secrets.env" "${REPO_ROOT}/tofu/secrets.auto.tfvars"; do
    if [ -f "${sec_file}" ]; then
        MATCHES=$(grep -rnE "10\.0\.0\.[0-9]+" "${sec_file}" 2>/dev/null || true)
        if [ -n "${MATCHES}" ]; then
            echo "[-] ERROR: Upstream template IP (10.0.0.x) found in secret file '${sec_file}':" >&2
            print_indented_errors "${MATCHES}"
            FAILED=1
        fi
    fi
done

# ------------------------------------------------------------------------------
# 2. Gate B: Ensure NO 192.168.1.x in Public Core Scope
# ------------------------------------------------------------------------------
echo "[*] Checking Public Core Scope (forbidding 192.168.1.x in public files)..."

# Inspect git-tracked files excluding private instance paths, local state & gitignored secrets,
# and excluding this script itself to prevent regex self-matching.
CORE_VIOLATIONS=$(git -C "${REPO_ROOT}" grep -nE "192\.168\.1\.[0-9]+" -- \
    ':!*instance*' \
    ':!homelab-secrets.env' \
    ':!tofu/terraform.tfvars' \
    ':!tofu/secrets.auto.tfvars' \
    ':!tofu/terraform.tfstate*' \
    ':!*.env' \
    ':!scripts/check-subnet-isolation.sh' 2>/dev/null || true)

if [ -n "${CORE_VIOLATIONS}" ]; then
    echo "[-] ERROR: Private physical IP (192.168.1.x) leaked into public core repository:" >&2
    print_indented_errors "${CORE_VIOLATIONS}"
    FAILED=1
fi

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
if [ ${FAILED} -ne 0 ]; then
    echo "=============================================================================="
    echo "[-] FAILED: Bidirectional Subnet Isolation Gate reported violations." >&2
    echo "[-] Fix: Replace 10.0.0.x in instance files with 192.168.1.x," >&2
    echo "[-]      and use dynamic environment variables in core files instead of 192.168.1.x." >&2
    echo "=============================================================================="
    exit 1
fi

echo "[+] PASSED: Bidirectional subnet isolation verified successfully."
exit 0
