#!/usr/bin/env bash
# ==============================================================================
# Homelab Security & Compliance Scanner
# ==============================================================================
# Runs local DevSecOps checks across OpenTofu, Shell scripts, and Stacks:
#   1. Pre-commit hooks (Gitleaks, ShellCheck, Tofu fmt)
#   2. OpenTofu schema validation (tofu validate)
#   3. Checkov / Trivy static analysis (if installed)
#
# Usage:
#   ./scripts/scan-security.sh [--discord] [--report]
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source secrets if present for webhooks
if [ -f "${REPO_ROOT}/secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/secrets.env"
elif [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

SEND_DISCORD=false
GENERATE_REPORT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --discord)
            SEND_DISCORD=true
            shift
            ;;
        --report)
            GENERATE_REPORT=true
            shift
            ;;
        *)
            shift
            ;;
    esac
done

REPORT_FILE=""
if [ "${GENERATE_REPORT}" = true ]; then
    mkdir -p "${REPO_ROOT}/reports"
    REPORT_FILE="${REPO_ROOT}/reports/security-audit-$(date '+%Y%m%d-%H%M%S').txt"
    exec > >(tee -a "${REPORT_FILE}") 2>&1
fi

echo "=============================================================================="
echo "    🛡️  Homelab Infrastructure Security & Quality Scanner                    "
echo "=============================================================================="

cd "${REPO_ROOT}"

FAILURES=0

# 1. ShellCheck Linting
echo "[*] Running ShellCheck on all shell scripts..."
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck "${REPO_ROOT}"/scripts/*.sh; then
        echo "[+] ShellCheck passed (0 lint errors)."
    else
        echo "[-] ShellCheck found issues."
        FAILURES=$((FAILURES + 1))
    fi
else
    echo "[!] ShellCheck not installed, skipping."
fi

# 2. OpenTofu Format & Validation
echo "[*] Checking OpenTofu formatting and schema validity..."
if command -v tofu >/dev/null 2>&1; then
    cd "${REPO_ROOT}/tofu"
    if tofu fmt -check; then
        echo "[+] OpenTofu format check passed."
    else
        echo "[-] OpenTofu formatting issues detected. Run 'tofu fmt'."
        FAILURES=$((FAILURES + 1))
    fi

    if tofu validate; then
        echo "[+] OpenTofu validation passed."
    else
        echo "[-] OpenTofu validate failed."
        FAILURES=$((FAILURES + 1))
    fi
    cd "${REPO_ROOT}"
fi

# 3. Pre-Commit Hooks
if command -v pre-commit >/dev/null 2>&1; then
    echo "[*] Running pre-commit hooks..."
    if pre-commit run --all-files; then
        echo "[+] Pre-commit checks passed."
    else
        echo "[-] Pre-commit found issues."
        FAILURES=$((FAILURES + 1))
    fi
fi

# 4. Checkov IaC Security Analysis (if installed)
if command -v checkov >/dev/null 2>&1; then
    echo "[*] Running Checkov IaC scan..."
    if checkov --config-file "${REPO_ROOT}/.checkov.yaml" --directory "${REPO_ROOT}/tofu" --quiet; then
        echo "[+] Checkov scan passed."
    else
        echo "[-] Checkov scan found potential issues."
        FAILURES=$((FAILURES + 1))
    fi
fi

echo "=============================================================================="
SCAN_STATUS="PASSED"
STATUS_COLOR=65280
if [ "${FAILURES}" -gt 0 ]; then
    SCAN_STATUS="FAILED (${FAILURES} issues)"
    STATUS_COLOR=16711680
    echo "[-] Security scan completed with ${FAILURES} failure(s)."
else
    echo "[+] All security and quality checks PASSED!"
fi

WEBHOOK="${DISCORD_SECURITY_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}"
if [ "${SEND_DISCORD}" = true ] && [ -n "${WEBHOOK}" ]; then
    echo "[*] Dispatching Discord security audit alert..."
    curl -s -X POST "${WEBHOOK}" \
        -H "Content-Type: application/json" \
        -d "{
            \"embeds\": [{
                \"title\": \"🛡️ Daily Security & DevSecOps Audit: ${SCAN_STATUS}\",
                \"color\": ${STATUS_COLOR},
                \"fields\": [
                    {\"name\": \"Status\", \"value\": \"${SCAN_STATUS}\", \"inline\": true},
                    {\"name\": \"Host\", \"value\": \"$(hostname)\", \"inline\": true},
                    {\"name\": \"Failures\", \"value\": \"${FAILURES}\", \"inline\": true}
                ],
                \"timestamp\": \"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\"
            }]
        }" >/dev/null 2>&1 || echo "[-] Failed to deliver Discord webhook."
fi

if [ "${FAILURES}" -eq 0 ]; then
    exit 0
else
    exit 1
fi
