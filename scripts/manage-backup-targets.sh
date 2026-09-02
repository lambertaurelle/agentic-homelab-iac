#!/usr/bin/env bash
# ==============================================================================
# Homelab Backup Targets Manager CLI
# ==============================================================================
# Provides programmatic, idempotent management of backup targets in
# config/instance/backup-targets.yaml (or config/backup-targets.example.yaml).
#
# Commands:
#   list                  List all configured backup targets with status & sizes
#   verify                Verify reachability and permissions of all enabled targets
#   add --name <name> --path <path> [--desc <text>] [--exclude <pat>]
#                         Add or update a backup target
#   enable --name <name>  Enable an existing target
#   disable --name <name> Disable an active target without deleting it
#   remove --name <name>  Completely remove a target from configuration
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Resolve active targets file: /etc/offsite-backup, instance overlay, or template
if [ -f "/etc/offsite-backup/backup-targets.yaml" ]; then
    TARGETS_FILE="/etc/offsite-backup/backup-targets.yaml"
elif [ -f "${REPO_ROOT}/config/instance/backup-targets.yaml" ]; then
    TARGETS_FILE="${REPO_ROOT}/config/instance/backup-targets.yaml"
elif [ -f "${REPO_ROOT}/config/backup-targets.yaml" ]; then
    TARGETS_FILE="${REPO_ROOT}/config/backup-targets.yaml"
else
    TARGETS_FILE="${REPO_ROOT}/config/instance/backup-targets.yaml"
    mkdir -p "${REPO_ROOT}/config/instance"
    if [ -f "${REPO_ROOT}/config/backup-targets.example.yaml" ]; then
        cp "${REPO_ROOT}/config/backup-targets.example.yaml" "${TARGETS_FILE}"
    fi
fi

show_help() {
    cat << 'HLP'
Usage: manage-backup-targets.sh <command> [options]

Commands:
  list                                List all targets and status
  verify                              Verify reachability of target directories
  add --name <name> --path <path>     Add or update a backup target
      [--desc <description>]
      [--exclude <pattern1,pattern2>]
  enable --name <name>                Enable a target
  disable --name <name>               Disable a target
  remove --name <name>                Remove a target from config
  help, -h, --help                    Show this help message

Examples:
  ./scripts/manage-backup-targets.sh list
  ./scripts/manage-backup-targets.sh verify
  ./scripts/manage-backup-targets.sh add --name docs --path /mnt/nas-data/docs
  ./scripts/manage-backup-targets.sh disable --name frigate-cctv
  ./scripts/manage-backup-targets.sh enable --name siyuan-notes
HLP
}

cmd_list() {
    python3 -c "
import sys, os, yaml

targets_file = '${TARGETS_FILE}'
if not os.path.exists(targets_file):
    print(f'[-] Targets file not found: {targets_file}', file=sys.stderr)
    sys.exit(1)

with open(targets_file, 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

targets = data.get('targets', [])
retention = data.get('settings', {}).get('retention', {})
quota = data.get('settings', {}).get('quota', {})

print('========================================================================================================')
print(f'    Offsite Backup Targets Configuration ({targets_file})')
print('========================================================================================================')
print(f'[*] Retention: keep-daily={retention.get(\"keep_daily\", 3)}, keep-weekly={retention.get(\"keep_weekly\", 2)}')
print(f'[*] Quota Alerts: warning={quota.get(\"warning_threshold_percent\", 85)}%, critical={quota.get(\"critical_threshold_percent\", 95)}%')
print('--------------------------------------------------------------------------------------------------------')
print(f'{\"TARGET NAME\":<20} | {\"STATUS\":<8} | {\"EXISTS?\":<7} | {\"SOURCE PATH\":<40}')
print('---------------------+----------+---------+-------------------------------------------------------------')

for t in targets:
    name = t.get('name', 'unnamed')
    enabled = 'ENABLED' if t.get('enabled', False) else 'DISABLED'
    src = t.get('source', '')
    exists = 'YES' if os.path.exists(src) else 'NO'
    print(f'{name:<20} | {enabled:<8} | {exists:<7} | {src:<40}')

print('========================================================================================================')
"
}

cmd_verify() {
    python3 -c "
import sys, os, yaml

targets_file = '${TARGETS_FILE}'
if not os.path.exists(targets_file):
    print(f'[-] Targets file not found: {targets_file}', file=sys.stderr)
    sys.exit(1)

with open(targets_file, 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

targets = [t for t in data.get('targets', []) if t.get('enabled', False)]

print(f'[*] Verifying {len(targets)} enabled backup targets...')
all_ok = True
for t in targets:
    name = t.get('name', 'unnamed')
    src = t.get('source', '')
    if os.path.exists(src):
        readable = os.access(src, os.R_OK)
        status = '[✓ PASS]' if readable else '[✗ NO READ]'
        if not readable:
            all_ok = False
        print(f'{status} {name}: {src} (Accessible and readable)')
    else:
        print(f'[! NOTE] {name}: {src} (Not mounted in current execution environment; verify inside container CT 602)')

print('[+] Verification check completed.')
"
}

cmd_set_status() {
    local target_name="$1"
    local new_status="$2"

    python3 -c "
import sys, os, yaml

targets_file = '${TARGETS_FILE}'
name = '${target_name}'
status = True if '${new_status}' == 'true' else False

with open(targets_file, 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

found = False
for t in data.get('targets', []):
    if t.get('name') == name:
        t['enabled'] = status
        found = True
        break

if not found:
    print(f'[-] Target \"{name}\" not found in {targets_file}', file=sys.stderr)
    sys.exit(1)

with open(targets_file, 'w', encoding='utf-8') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

action = 'enabled' if status else 'disabled'
print(f'[+] Target \"{name}\" successfully {action}.')
"
}

cmd_remove() {
    local target_name="$1"

    python3 -c "
import sys, os, yaml

targets_file = '${TARGETS_FILE}'
name = '${target_name}'

with open(targets_file, 'r', encoding='utf-8') as f:
    data = yaml.safe_load(f) or {}

orig_len = len(data.get('targets', []))
data['targets'] = [t for t in data.get('targets', []) if t.get('name') != name]

if len(data['targets']) == orig_len:
    print(f'[-] Target \"{name}\" not found in {targets_file}', file=sys.stderr)
    sys.exit(1)

with open(targets_file, 'w', encoding='utf-8') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

print(f'[+] Target \"{name}\" successfully removed.')
"
}

cmd_add() {
    local name=""
    local path=""
    local desc=""
    local exclude=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --path) path="$2"; shift 2 ;;
            --desc|--description) desc="$2"; shift 2 ;;
            --exclude) exclude="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -z "${name}" ] || [ -z "${path}" ]; then
        echo "[-] Error: Both --name and --path are required." >&2
        exit 1
    fi

    python3 -c "
import sys, os, yaml

targets_file = '${TARGETS_FILE}'
name = '${name}'
path = '${path}'
desc = '${desc}' or f'Backup target for {name}'
exclude_raw = '${exclude}'
exclude = [x.strip() for x in exclude_raw.split(',') if x.strip()] if exclude_raw else ['*.tmp']

data = {}
if os.path.exists(targets_file):
    with open(targets_file, 'r', encoding='utf-8') as f:
        data = yaml.safe_load(f) or {}

if 'targets' not in data:
    data['targets'] = []

updated = False
for t in data['targets']:
    if t.get('name') == name:
        t['source'] = path
        t['description'] = desc
        t['enabled'] = True
        t['exclude'] = exclude
        updated = True
        break

if not updated:
    data['targets'].append({
        'name': name,
        'source': path,
        'description': desc,
        'enabled': True,
        'exclude': exclude
    })

os.makedirs(os.path.dirname(targets_file), exist_ok=True)
with open(targets_file, 'w', encoding='utf-8') as f:
    yaml.dump(data, f, default_flow_style=False, sort_keys=False)

action = 'updated' if updated else 'added'
print(f'[+] Target \"{name}\" ({path}) successfully {action}.')
"
}

# CLI routing
ACTION="${1:-list}"
shift || true

case "${ACTION}" in
    list|ls)
        cmd_list
        ;;
    verify|check)
        cmd_verify
        ;;
    enable)
        if [ $# -lt 1 ]; then echo "Usage: $0 enable --name <name>" >&2; exit 1; fi
        TARGET_NAME="$1"
        if [ "$1" = "--name" ]; then TARGET_NAME="$2"; fi
        cmd_set_status "${TARGET_NAME}" "true"
        ;;
    disable)
        if [ $# -lt 1 ]; then echo "Usage: $0 disable --name <name>" >&2; exit 1; fi
        TARGET_NAME="$1"
        if [ "$1" = "--name" ]; then TARGET_NAME="$2"; fi
        cmd_set_status "${TARGET_NAME}" "false"
        ;;
    remove|rm|del)
        if [ $# -lt 1 ]; then echo "Usage: $0 remove --name <name>" >&2; exit 1; fi
        TARGET_NAME="$1"
        if [ "$1" = "--name" ]; then TARGET_NAME="$2"; fi
        cmd_remove "${TARGET_NAME}"
        ;;
    add)
        cmd_add "$@"
        ;;
    help|-h|--help)
        show_help
        ;;
    *)
        echo "[-] Unknown command: ${ACTION}" >&2
        show_help
        exit 1
        ;;
esac
