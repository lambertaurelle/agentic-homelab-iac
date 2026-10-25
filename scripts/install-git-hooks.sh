#!/usr/bin/env bash
# ==============================================================================
# Install & Configure Local Git Hooks (scripts/install-git-hooks.sh)
# ==============================================================================
# Configures core.hooksPath and installs pre-commit / pre-push guardrails.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${REPO_ROOT}"

echo "[*] Configuring Git hooks..."

# 1. Install pre-commit framework hooks if pre-commit is installed
if command -v pre-commit >/dev/null 2>&1; then
    pre-commit install --hook-type pre-commit
    echo "[+] pre-commit hook active in .git/hooks/pre-commit"
fi

# 2. Copy/symlink pre-push guardrail
mkdir -p "${REPO_ROOT}/.git/hooks"
cp -a "${REPO_ROOT}/.githooks/pre-push" "${REPO_ROOT}/.git/hooks/pre-push"
chmod +x "${REPO_ROOT}/.git/hooks/pre-push"
echo "[+] pre-push guardrail installed to .git/hooks/pre-push"

echo "[+] All Git security hooks installed and active."
