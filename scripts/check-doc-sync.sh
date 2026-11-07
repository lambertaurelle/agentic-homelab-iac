#!/usr/bin/env bash
# ==============================================================================
# Code <-> Documentation Coherence & Synchronization Gate
# ==============================================================================
# Modes:
#   --git-hook : Verifies that doc files are touched when code changes.
#   --audit    : Structurally validates docs/instance/INVENTORY.md against tofu/*.tf.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

MODE="${1:---audit}"

echo "=============================================================================="
echo "    Documentation <-> Code Synchronization Gate (${MODE})                     "
echo "=============================================================================="

# ------------------------------------------------------------------------------
# Mode 1: Git Hook Change Verification
# ------------------------------------------------------------------------------
if [ "${MODE}" = "--git-hook" ]; then
    # Detect modified files in staged index or outgoing commits
    CHANGED_FILES=$(git -C "${REPO_ROOT}" diff --cached --name-only 2>/dev/null || true)
    if [ -z "${CHANGED_FILES}" ]; then
        CHANGED_FILES=$(git -C "${REPO_ROOT}" diff HEAD~1 --name-only 2>/dev/null || true)
    fi

    if [ -z "${CHANGED_FILES}" ]; then
        echo "[*] No staged changes detected. Skipping."
        exit 0
    fi

    TOUCHED_INSTANCE_CODE=false
    TOUCHED_INSTANCE_DOC=false
    TOUCHED_CORE_CODE=false
    TOUCHED_CORE_DOC=false

    while IFS= read -r f; do
        [ -z "$f" ] && continue
        [[ "$f" =~ ^(tofu/instance-|stacks/instance/|scripts/instance/) ]] && TOUCHED_INSTANCE_CODE=true
        [[ "$f" =~ ^docs/instance/ ]] && TOUCHED_INSTANCE_DOC=true
        [[ "$f" =~ ^(tofu/ct-|stacks/monitoring/|scripts/) && ! "$f" =~ instance ]] && TOUCHED_CORE_CODE=true
        [[ "$f" =~ ^(docs/[^/]+\.md|README\.md) ]] && TOUCHED_CORE_DOC=true
    done <<< "${CHANGED_FILES}"

    if [ "${TOUCHED_INSTANCE_CODE}" = true ] && [ "${TOUCHED_INSTANCE_DOC}" = false ]; then
        echo "[-] ERROR: Private instance code was modified without corresponding documentation updates!" >&2
        echo "[-] You MUST update docs/instance/ (e.g. INVENTORY.md, TOPOLOGY.md) in the same commit." >&2
        exit 1
    fi

    if [ "${TOUCHED_CORE_CODE}" = true ] && [ "${TOUCHED_CORE_DOC}" = false ]; then
        echo "[-] ERROR: Core public code was modified without corresponding documentation updates!" >&2
        echo "[-] You MUST update public documentation under docs/*.md or README.md in the same commit." >&2
        exit 1
    fi

    echo "[+] Documentation change gate passed: docs updated alongside code changes."
    exit 0
fi

# ------------------------------------------------------------------------------
# Mode 2: Structural Inventory Audit vs OpenTofu Definitions
# ------------------------------------------------------------------------------
INVENTORY_FILE="${REPO_ROOT}/docs/instance/INVENTORY.md"

if [ ! -f "${INVENTORY_FILE}" ]; then
    echo "[*] Notice: Instance inventory not present (public core template scope). Skipping instance inventory audit."
    exit 0
fi

echo "[*] Auditing ${INVENTORY_FILE} against OpenTofu declarations..."

export REPO_ROOT
python3 - << 'PYEOF'
import os, re, sys

repo_root = os.environ.get("REPO_ROOT", ".")
inventory_path = os.path.join(repo_root, "docs/instance/INVENTORY.md")
tofu_dir = os.path.join(repo_root, "tofu")

with open(inventory_path, "r", encoding="utf-8") as f:
    inv_text = f.read()

# Check for forbidden 10.0.0.x in inventory
if re.search(r"10\.0\.0\.[0-9]+", inv_text):
    print("[-] AUDIT ERROR: INVENTORY.md still contains template IP 10.0.0.x! Must be 192.168.1.x.", file=sys.stderr)
    sys.exit(1)

# Extract variable defaults across all .tf files
var_defaults = {}
for fname in os.listdir(tofu_dir):
    if not fname.endswith(".tf"):
        continue
    with open(os.path.join(tofu_dir, fname), "r", encoding="utf-8") as f:
        content = f.read()
    for m in re.finditer(r'variable\s+"([a-zA-Z0-9_]+)"\s*\{[^}]*default\s*=\s*([0-9]+)', content):
        var_defaults[m.group(1)] = int(m.group(2))

# Extract declared containers from tofu
declared_cts = {}
for fname in os.listdir(tofu_dir):
    if not fname.endswith(".tf"):
        continue
    fpath = os.path.join(tofu_dir, fname)
    with open(fpath, "r", encoding="utf-8") as f:
        content = f.read()

    # Find literal vm_id = <number>
    for m in re.finditer(r'vm_id\s*=\s*([0-9]+)', content):
        ctid = int(m.group(1))
        declared_cts[ctid] = fname

    # Find vm_id = var.<name>
    for m in re.finditer(r'vm_id\s*=\s*var\.([a-zA-Z0-9_]+)', content):
        varname = m.group(1)
        if varname in var_defaults:
            declared_cts[var_defaults[varname]] = fname

print(f"[*] Discovered {len(declared_cts)} container declarations in OpenTofu.")

# Validate that every declared CTID is documented in INVENTORY.md
missing_in_doc = []
for ctid in sorted(declared_cts.keys()):
    pattern = rf'\|\s*\*\*?{ctid}\*\*?\s*\|'
    if not re.search(pattern, inv_text):
        missing_in_doc.append(ctid)

if missing_in_doc:
    print(f"[-] AUDIT ERROR: The following containers declared in OpenTofu are MISSING from INVENTORY.md: {missing_in_doc}", file=sys.stderr)
    sys.exit(1)

print("[+] PASSED: All OpenTofu containers are documented in INVENTORY.md.")
sys.exit(0)
PYEOF

echo "[+] Structural documentation audit passed with 100% coherence."
exit 0
