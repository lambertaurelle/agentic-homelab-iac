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
#   ./scripts/scan-security.sh
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

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
if [ "${FAILURES}" -eq 0 ]; then
    echo "[+] All security and quality checks PASSED!"
    exit 0
else
    echo "[-] Security scan completed with ${FAILURES} failure(s)."
    exit 1
fi
