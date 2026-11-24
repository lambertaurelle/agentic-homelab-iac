#!/usr/bin/env bash
# ==============================================================================
# Documentation vs Live Cluster, Backups & Restore Coherence Auditor
# Path: scripts/audit-doc-vs-live.sh
# Target: Management Workspace (CT 900 mgmt-devops)
# ==============================================================================
# Logic:
#   1. Runs deterministic read-only probes comparing live cluster (Proxmox LXCs,
#      vzdump.cron, NAS mounts, CT 602 bind mounts, backup-targets.yaml, HAOS)
#      against OpenTofu and documentation (INVENTORY.md, STORAGE_AND_BACKUPS.md,
#      RESTORE_RUNBOOK.md, HOME_ASSISTANT.md, DISASTER_RECOVERY.md).
#   2. Zero LLM tokens consumed when 100% in sync (unless --notify-ok is passed).
#   3. If any drift/gap is detected (unless --dry-run):
#      - Creates a persistent, interactive Antigravity Phase 1 session via `agy`
#      - Restarts `antigravity-cli-daemon.service` so Web UI shows it immediately
#      - Sends a red Discord embed to #monitoring with the gaps + Conversation ID
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

DRY_RUN=false
NOTIFY_OK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--check|-n)
            DRY_RUN=true
            shift
            ;;
        --notify-ok)
            NOTIFY_OK=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--dry-run] [--notify-ok]"
            exit 0
            ;;
        *)
            echo "[-] Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

DISCORD_WEBHOOK="${DISCORD_MONITORING_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}"
AGY_BIN="/root/.local/bin/agy"
AGY_TARGET_MODEL="${ANTIGRAVITY_MODEL:-gemini-4-argon-high}"
AGY_PROJECT_ID="${ANTIGRAVITY_PROJECT_ID:-}"
AGY_PROJECT_ARGS=()
if [ -n "${AGY_PROJECT_ID}" ]; then
    AGY_PROJECT_ARGS=(--project "${AGY_PROJECT_ID}")
fi
PVE_EXEC="${SCRIPT_DIR}/pve-exec.sh"
HA_EXEC="${SCRIPT_DIR}/instance/ha-exec.sh"
HA_API="${SCRIPT_DIR}/instance/ha-api.sh"
TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
TODAY_DATE="$(date +'%Y-%m-%d')"

DRIFT_ITEMS=()
log_info()  { echo "[*] [doc-audit] $*"; }
log_ok()    { echo "[+] [doc-audit] $*"; }
log_drift() { echo "[-] [doc-audit] [DRIFT] $*"; DRIFT_ITEMS+=("$*"); }

echo "=============================================================================="
echo "    Documentation vs Live Stack & Restore Auditor — $(date '+%Y-%m-%d %H:%M')"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Gather Live Proxmox State (node-1 & node-2)
# ------------------------------------------------------------------------------
log_info "Collecte de l'état live Proxmox (LXCs, vzdump, syno-backup, CT 602 sync)..."
LIVE_LXC_JSON=$(
    "${PVE_EXEC}" node-1 "
        python3 - << 'PYPVE'
import hashlib, json, os, re, subprocess, time

cts = {}
res = subprocess.check_output(['pvesh', 'get', '/cluster/resources', '--type', 'vm', '--output-format', 'json'], text=True)
for item in json.loads(res):
    if item.get('type') != 'lxc':
        continue
    vmid = str(item['vmid'])
    node = item['node']
    status = item.get('status', 'unknown')
    conf_path = f'/etc/pve/nodes/{node}/lxc/{vmid}.conf'
    conf = {}
    if os.path.exists(conf_path):
        with open(conf_path) as f:
            for line in f:
                if ':' in line:
                    k, v = line.split(':', 1)
                    conf[k.strip()] = v.strip()
    cts[vmid] = {
        'node': node,
        'status': status,
        'hostname': conf.get('hostname', ''),
        'cores': int(conf.get('cores', 0) or 0),
        'memory': int(conf.get('memory', 0) or 0),
        'swap': int(conf.get('swap', 0) or 0),
        'unprivileged': conf.get('unprivileged', '0') == '1',
        'onboot': conf.get('onboot', '0') == '1',
        'mps': {k: v for k, v in conf.items() if re.match(r'^mp\d+$', k)},
        'rootfs': conf.get('rootfs', ''),
        'net0': conf.get('net0', ''),
    }

vzdump_cts = []
vzdump_compress = ''
if os.path.exists('/etc/pve/vzdump.cron'):
    with open('/etc/pve/vzdump.cron') as f:
        for line in f:
            m = re.search(r'vzdump\s+([0-9 ]+)', line)
            if m:
                vzdump_cts = m.group(1).split()
            mc = re.search(r'--compress\s+(\S+)', line)
            if mc:
                vzdump_compress = mc.group(1)

fstab_mounts = []
if os.path.exists('/etc/fstab'):
    with open('/etc/fstab') as f:
        for line in f:
            s = line.strip()
            if s and not s.startswith('#') and 'nfs' in s:
                fstab_mounts.append(s)

recent_dumps = []
dump_dir = '/mnt/pve/syno-backup/dump'
if os.path.isdir(dump_dir):
    cutoff = time.time() - 93600  # 26h tolerance window
    for fn in os.listdir(dump_dir):
        if fn.startswith('vzdump-lxc-') and '.tar' in fn and not fn.endswith('.log'):
            fp = os.path.join(dump_dir, fn)
            if os.path.getmtime(fp) >= cutoff:
                m = re.match(r'vzdump-lxc-(\d+)-', fn)
                if m:
                    recent_dumps.append(m.group(1))

synced_targets_sha256 = ''
sync_yaml = '/var/lib/homelab-offsite-sync/backup-targets.yaml'
if os.path.isfile(sync_yaml):
    with open(sync_yaml, 'rb') as f:
        synced_targets_sha256 = hashlib.sha256(f.read()).hexdigest()

print(json.dumps({
    'cts': cts,
    'vzdump_cts': sorted(set(vzdump_cts), key=int),
    'vzdump_compress': vzdump_compress,
    'fstab_nfs': fstab_mounts,
    'recent_dumps': sorted(set(recent_dumps), key=int),
    'synced_targets_sha256': synced_targets_sha256,
}))
PYPVE
    " 2>/dev/null | sed -n '/^{/,$p' | jq -c . 2>/dev/null || echo ""
)

if [ -z "${LIVE_LXC_JSON}" ]; then
    log_drift "Cluster Proxmox injoignable pour collecter l'état live des LXC."
fi

# ------------------------------------------------------------------------------
# 2. Gather Live HAOS State (from CT 900 wrappers if instance overlay active)
# ------------------------------------------------------------------------------
HA_MOUNTS_JSON=""
HA_BACKUPS_JSON=""
HA_NEXT_BACKUP_JSON=""
HAS_HA_INSTANCE=false

if [ -x "${HA_EXEC}" ]; then
    HAS_HA_INSTANCE=true
    log_info "Collecte de l'état live HAOS (montages Supervisor, snapshots, planification)..."
    HA_MOUNTS_JSON=$("${HA_EXEC}" "ha mounts info --raw-json" 2>/dev/null | sed -n '/^{/,$p' | jq -c . 2>/dev/null || echo "")
    HA_BACKUPS_JSON=$("${HA_EXEC}" "ha backups list --raw-json" 2>/dev/null | sed -n '/^{/,$p' | jq -c . 2>/dev/null || echo "")
fi
if [ -x "${HA_API}" ]; then
    HA_NEXT_BACKUP_JSON=$("${HA_API}" GET states/sensor.backup_next_scheduled_automatic_backup 2>/dev/null | sed -n '/^{/,$p' | jq -c . 2>/dev/null || echo "")
fi

# ------------------------------------------------------------------------------
# 3. Deterministic Cross-Audit (Python)
# ------------------------------------------------------------------------------
log_info "Exécution de l'audit croisé déterministe (Docs vs Stack Live & Runbooks)..."
export REPO_ROOT LIVE_LXC_JSON HA_MOUNTS_JSON HA_BACKUPS_JSON HA_NEXT_BACKUP_JSON HAS_HA_INSTANCE
AUDIT_REPORT=$(python3 - << 'PYEOF'
from datetime import datetime, timezone
import hashlib, json, os, re

try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

repo_root = os.environ["REPO_ROOT"]
live_raw = os.environ.get("LIVE_LXC_JSON", "").strip()
ha_mounts_raw = os.environ.get("HA_MOUNTS_JSON", "").strip()
ha_backups_raw = os.environ.get("HA_BACKUPS_JSON", "").strip()
ha_next_raw = os.environ.get("HA_NEXT_BACKUP_JSON", "").strip()
has_ha = os.environ.get("HAS_HA_INSTANCE") == "true"
has_instance_docs = os.path.isdir(os.path.join(repo_root, "docs/instance"))

drifts = []

def read_text(rel_path):
    p = os.path.join(repo_root, rel_path)
    if not os.path.exists(p):
        return None
    with open(p, "r", encoding="utf-8") as f:
        return f.read()

inv_txt = read_text("docs/instance/INVENTORY.md")
stor_txt = read_text("docs/instance/STORAGE_AND_BACKUPS.md")
rest_txt = read_text("docs/instance/RESTORE_RUNBOOK.md")
ha_doc_txt = read_text("docs/instance/HOME_ASSISTANT.md")
dr_txt = read_text("docs/DISASTER_RECOVERY.md")

if has_instance_docs:
    if inv_txt is None:
        drifts.append("Fichier docs/instance/INVENTORY.md absent.")
    if stor_txt is None:
        drifts.append("Fichier docs/instance/STORAGE_AND_BACKUPS.md absent.")
    if rest_txt is None:
        drifts.append("Fichier docs/instance/RESTORE_RUNBOOK.md absent.")

# 3a. Parse INVENTORY.md table rows
inv_rows = {}
if inv_txt:
    for line in inv_txt.splitlines():
        m = re.match(r'^\|\s*\*\*(\d+)\*\*\s*\|\s*([^|]+)\|\s*`([^`]+)`\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*(\d+)\s*\|\s*([^|]+)\|\s*([^|]+)\|\s*([^|]+)\|', line)
        if m:
            ctid = m.group(1)
            inv_rows[ctid] = {
                "hostname": m.group(2).strip(),
                "node": m.group(3).strip(),
                "cores": int(m.group(4)),
                "memory": int(m.group(5)),
                "swap": int(m.group(6)),
                "disk": m.group(7).strip(),
                "priv": m.group(8).strip(),
                "startup": m.group(9).strip(),
            }

# 3b. Compare Live LXCs vs INVENTORY.md, VZDump & RESTORE_RUNBOOK
excluded_vzdump = set(os.environ.get("DOC_AUDIT_EXCLUDED_CTS", "601 602 901").split())
if live_raw and has_instance_docs:
    live = json.loads(live_raw)
    cts = live.get("cts", {})
    vzdump_cts = set(live.get("vzdump_cts", []))
    recent_dumps = set(live.get("recent_dumps", []))

    for ctid, info in sorted(cts.items(), key=lambda x: int(x[0])):
        if ctid not in inv_rows:
            drifts.append(f"CT {ctid} ({info['hostname']}) présent sur Proxmox ({info['node']}) mais ABSENT de docs/instance/INVENTORY.md.")
        else:
            row = inv_rows[ctid]
            if row["node"] != info["node"]:
                drifts.append(f"CT {ctid}: nœud doc='{row['node']}' vs live='{info['node']}'.")
            if info["hostname"] not in row["hostname"]:
                drifts.append(f"CT {ctid}: hostname doc='{row['hostname']}' vs live='{info['hostname']}'.")
            if row["cores"] != info["cores"] or row["memory"] != info["memory"]:
                drifts.append(f"CT {ctid}: ressources doc={row['cores']}C/{row['memory']}MB vs live={info['cores']}C/{info['memory']}MB.")
            doc_unpriv = "unprivileged" in row["priv"].lower()
            if doc_unpriv != info["unprivileged"]:
                drifts.append(f"CT {ctid}: privilège doc='{row['priv']}' vs live unprivileged={info['unprivileged']}.")
            if info["status"] == "running" and "disabled" in row["startup"].lower():
                drifts.append(f"CT {ctid}: marqué Disabled/Stopped dans INVENTORY.md alors qu'il est RUNNING en prod.")

        if ctid not in excluded_vzdump:
            if ctid not in vzdump_cts:
                drifts.append(f"CT {ctid} ({info['hostname']}) actif/non-exclu mais ABSENT de /etc/pve/vzdump.cron !")
            elif ctid not in recent_dumps:
                drifts.append(f"CT {ctid} ({info['hostname']}) présent dans vzdump.cron mais sans archive (<26h) sur syno-backup.")

        if rest_txt and not re.search(rf'\bCT\s*{ctid}\b', rest_txt):
            drifts.append(f"CT {ctid} ({info['hostname']}) n'a pas de référence explicite dans docs/instance/RESTORE_RUNBOOK.md.")

    for ctid in inv_rows:
        if ctid not in cts:
            drifts.append(f"CT {ctid} présent dans INVENTORY.md mais inexistant sur le cluster Proxmox.")

    # Check CT 602 bind mounts & staged YAML SHA256
    ct602 = cts.get("602", {})
    mps602 = list(ct602.get("mps", {}).values())
    targets_file = os.path.join(repo_root, "config/instance/backup-targets.yaml")
    if os.path.exists(targets_file):
        try:
            import yaml
            with open(targets_file) as f:
                tdata_mps = yaml.safe_load(f) or {}
            for t in tdata_mps.get("targets", []):
                if not t.get("enabled", False):
                    continue
                src = t.get("source", "")
                if src.startswith("/mnt/backup-source/") and not any(src in m for m in mps602):
                    drifts.append(f"CT 602 (offsite-backup) n'a pas le montage {src} requis par backup-targets.yaml.")
        except Exception as e:
            drifts.append(f"Erreur lecture config/instance/backup-targets.yaml pour vérification montages CT 602: {e}")
    if not any("/mnt/offsite-sync" in m for m in mps602):
        drifts.append("CT 602 (offsite-backup) n'a pas le montage /mnt/offsite-sync (mp4).")

    synced_sha = live.get("synced_targets_sha256", "")
    if os.path.exists(targets_file):
        with open(targets_file, "rb") as f:
            repo_sha = hashlib.sha256(f.read()).hexdigest()
        if not synced_sha:
            drifts.append("node-1:/var/lib/homelab-offsite-sync/backup-targets.yaml introuvable (staging CT 602 manquant).")
        elif synced_sha != repo_sha:
            drifts.append("node-1:/var/lib/homelab-offsite-sync/backup-targets.yaml désynchronisé de config/instance/backup-targets.yaml.")

    if stor_txt and "--compress 0" not in stor_txt and live.get("vzdump_compress") == "0":
        drifts.append("docs/instance/STORAGE_AND_BACKUPS.md ne reflète pas --compress 0 de vzdump.cron.")

# 3c. Check backup-targets.yaml vs STORAGE_AND_BACKUPS.md & RESTORE_RUNBOOK.md
targets_file = os.path.join(repo_root, "config/instance/backup-targets.yaml")
if has_instance_docs and os.path.exists(targets_file):
    try:
        import yaml
        with open(targets_file) as f:
            tdata = yaml.safe_load(f) or {}
        for t in tdata.get("targets", []):
            if not t.get("enabled", False):
                continue
            name = t.get("name", "")
            src = t.get("source", "")
            if stor_txt and name not in stor_txt:
                drifts.append(f"Cible Restic active '{name}' ({src}) absente de docs/instance/STORAGE_AND_BACKUPS.md.")
            if rest_txt and name not in rest_txt:
                drifts.append(f"Cible Restic active '{name}' ({src}) sans procédure de restauration dans docs/instance/RESTORE_RUNBOOK.md.")
    except Exception as e:
        drifts.append(f"Erreur lecture config/instance/backup-targets.yaml: {e}")

# 3d. Check DISASTER_RECOVERY.md has no ro=1 target bug
if dr_txt:
    if re.search(r'restic restore .*--target /mnt/backup-source/', dr_txt):
        drifts.append("docs/DISASTER_RECOVERY.md contient une commande restic restore vers /mnt/backup-source/ (monté en ro=1 dans CT 602).")

# 3e. Check HAOS mounts, snapshot freshness, scheduled backup & docs alignment
if has_ha and has_instance_docs:
    expected_ha_mounts = os.environ.get("HAOS_EXPECTED_MOUNTS", "").split()
    ha_backup_time = os.environ.get("HAOS_BACKUP_HOUR", "02:00")
    try:
        ha_bk_hour, ha_bk_min = (int(p) for p in ha_backup_time.split(":")[:2])
    except ValueError:
        ha_bk_hour, ha_bk_min = 2, 0

    if not ha_mounts_raw:
        drifts.append("HAOS injoignable ou sortie JSON invalide pour 'ha mounts info --raw-json'.")
    else:
        try:
            mdata = json.loads(ha_mounts_raw).get("data", {})
            mount_names = {m.get("name") for m in mdata.get("mounts", []) if m.get("state") == "active"}
            for expected in expected_ha_mounts:
                if expected not in mount_names:
                    drifts.append(f"HAOS : montage Supervisor actif '{expected}' manquant.")
        except Exception as e:
            drifts.append(f"HAOS : erreur parsing ha mounts info ({e}).")

    if ha_backups_raw:
        try:
            bks = json.loads(ha_backups_raw).get("data", {}).get("backups", [])
            now_utc = datetime.now(timezone.utc)
            fresh_backup = False
            primary_ha_mount = expected_ha_mounts[0] if expected_ha_mounts else ""
            for b in bks:
                locs = b.get("locations") or ([b.get("location")] if b.get("location") else [])
                if primary_ha_mount and primary_ha_mount not in locs:
                    continue
                bdate = b.get("date")
                if bdate:
                    dt = datetime.fromisoformat(bdate.replace("Z", "+00:00"))
                    if (now_utc - dt).total_seconds() <= 36 * 3600:
                        fresh_backup = True
                        break
            if not fresh_backup:
                loc_hint = f" sur le montage {primary_ha_mount}" if primary_ha_mount else ""
                drifts.append(f"HAOS : aucun snapshot (<36h) présent{loc_hint}.")
        except Exception as e:
            drifts.append(f"HAOS : erreur parsing ha backups list ({e}).")

    if ha_next_raw:
        try:
            st = json.loads(ha_next_raw).get("state", "")
            if st and st not in ("unknown", "unavailable"):
                dt = datetime.fromisoformat(st.replace("Z", "+00:00"))
                local_dt = dt.astimezone(ZoneInfo("Europe/Paris")) if ZoneInfo else dt
                if (local_dt.hour, local_dt.minute) != (ha_bk_hour, ha_bk_min):
                    drifts.append(f"HAOS : prochain backup automatique planifié à {local_dt.strftime('%H:%M')} Europe/Paris au lieu de {ha_bk_hour:02d}:{ha_bk_min:02d}.")
        except Exception:
            pass

    if ha_doc_txt and f"{ha_bk_hour:02d}:{ha_bk_min:02d}" not in ha_doc_txt:
        drifts.append(f"docs/instance/HOME_ASSISTANT.md ne mentionne pas la planification backup {ha_bk_hour:02d}:{ha_bk_min:02d}.")
    if rest_txt and "HAOS" not in rest_txt:
        drifts.append("docs/instance/RESTORE_RUNBOOK.md ne couvre pas la restauration Bare Metal HAOS.")

for d in drifts:
    print(d)
PYEOF
)

if [ -n "${AUDIT_REPORT}" ]; then
    while IFS= read -r line; do
        [ -n "${line}" ] && log_drift "${line}"
    done <<< "${AUDIT_REPORT}"
fi

# Run existing structural check-doc-sync.sh --audit & subnet isolation
if [ -x "${SCRIPT_DIR}/check-doc-sync.sh" ]; then
    if ! "${SCRIPT_DIR}/check-doc-sync.sh" --audit >/dev/null 2>&1; then
        log_drift "check-doc-sync.sh --audit a échoué (INVENTORY.md vs tofu/*.tf)."
    fi
fi
if [ -x "${SCRIPT_DIR}/check-subnet-isolation.sh" ]; then
    if ! "${SCRIPT_DIR}/check-subnet-isolation.sh" >/dev/null 2>&1; then
        log_drift "check-subnet-isolation.sh a détecté une fuite d'adressage."
    fi
fi

echo "=============================================================================="

# ------------------------------------------------------------------------------
# 4. Nominal Result (0 Drift)
# ------------------------------------------------------------------------------
if [ "${#DRIFT_ITEMS[@]}" -eq 0 ]; then
    log_ok "BILAN DOC-VS-LIVE : 100% conforme (0 écart entre documentation, backups, restore et stack live)."
    if [ "${NOTIFY_OK}" = true ] && [ -n "${DISCORD_WEBHOOK}" ]; then
        python3 - "${DISCORD_WEBHOOK}" "${TIMESTAMP}" << 'EOF'
import json, sys, urllib.request
webhook_url, ts = sys.argv[1], sys.argv[2]
payload = {
    "embeds": [{
        "title": "✅ Audit Doc vs Stack Live — 100% Conforme",
        "description": "La documentation d'inventaire, de stockage, de backups et les procédures de restore reflètent fidèlement l'état live (Proxmox, Restic, HAOS).",
        "color": 3066993,
        "footer": {"text": "Doc-vs-Live Coherence Auditor • CT 900 • 0 token LLM"},
        "timestamp": ts
    }]
}
req = urllib.request.Request(webhook_url, data=json.dumps(payload).encode("utf-8"), headers={"Content-Type": "application/json", "User-Agent": "Homelab-DocAudit/1.0"})
urllib.request.urlopen(req)
EOF
    fi
    exit 0
fi

# ------------------------------------------------------------------------------
# 5. Drift Detected -> Dry-Run Stop OR Spawn Interactive Antigravity + Discord
# ------------------------------------------------------------------------------
log_drift "BILAN DOC-VS-LIVE : ${#DRIFT_ITEMS[@]} écart(s) détecté(s) !"

DRIFT_MD=""
for item in "${DRIFT_ITEMS[@]}"; do
    DRIFT_MD+=$'\n'"- ❌ ${item}"
done

if [ "${DRY_RUN}" = true ]; then
    echo "[DRY-RUN] Écarts détectés (aucune session agy ni ping Discord envoyé) :"
    echo "${DRIFT_MD}"
    exit 2
fi

PROMPT="[DOC-DRIFT ALERT ${TODAY_DATE}] ${#DRIFT_ITEMS[@]} écart(s) Doc vs Stack Live détecté(s)
[PHASE 1 — ANALYSE, RECHERCHE & PLANIFICATION FLASH-READY | Model: \"pro\" | READ-ONLY]

L'audit automatique quotidien (scripts/audit-doc-vs-live.sh) a détecté ${#DRIFT_ITEMS[@]} divergence(s) entre la documentation (inventaire, configuration backups, runbooks de restore) et l'infrastructure en cours d'exécution :
${DRIFT_MD}

Consignes strictes :
1. En mode strictement lecture seule, vérifie l'état réel sur Proxmox, Restic (via inspect-backup.sh) et HAOS.
2. Prépare un plan Flash-Ready dans <artifact-dir>/scratch/plan_draft.md et publie <artifact-dir>/implementation_plan.md pour mettre à jour fidèlement la documentation et les runbooks de restore (ou corriger la dérive de backup détectée).
3. Attends ma réponse / validation dans cette conversation avant d'appliquer toute modification."

CONV_ID="session-pending"
if [ -x "${AGY_BIN}" ]; then
    cd "${REPO_ROOT}"
    CLI_JSON_OUTPUT=$("${AGY_BIN}" \
        --mode plan \
        --model "${AGY_TARGET_MODEL}" \
        "${AGY_PROJECT_ARGS[@]}" \
        --dangerously-skip-permissions \
        --output-format json \
        -p "${PROMPT}" 2>&1 || true)

    CONV_ID=$(echo "${CLI_JSON_OUTPUT}" | jq -r '.conversation_id // .conversationId // empty' 2>/dev/null || true)
    if [ -z "${CONV_ID}" ]; then
        CONV_ID=$(find /root/.gemini/antigravity-cli/brain -maxdepth 1 -mindepth 1 -type d -cmin -5 -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -n1 | awk '{print $2}' || true)
    fi
    if [ -n "${CONV_ID}" ] && [ "${CONV_ID}" != "session-pending" ]; then
        log_ok "Conversation Antigravity créée : ${CONV_ID}"
        PLAN_SRC="/root/.gemini/antigravity-cli/brain/${CONV_ID}/implementation_plan.md"
        if [ -f "${PLAN_SRC}" ]; then
            cp -f "${PLAN_SRC}" "${REPO_ROOT}/doc_drift_plan.md"
        fi
        UID_VAL=$(id -u)
        export XDG_RUNTIME_DIR="/run/user/${UID_VAL}"
        systemctl --user restart antigravity-cli-daemon.service 2>/dev/null || true
    else
        CONV_ID="session-pending"
    fi
else
    CONV_ID="agy-binary-not-found"
fi

if [ -n "${DISCORD_WEBHOOK}" ]; then
    python3 - "${DRIFT_MD}" "${CONV_ID}" "${DISCORD_WEBHOOK}" "${TIMESTAMP}" "${#DRIFT_ITEMS[@]}" << 'EOF'
import json, sys, urllib.request

drift_list, conv_id, webhook_url, ts, count = sys.argv[1:6]
payload = {
    "embeds": [{
        "title": f"📚🚨 Dérive Documentation vs Stack Live ({count} écart(s))",
        "description": "La documentation (inventaire, backups ou procédures de restore) ne correspond plus exactement à la stack en cours d'exécution. Une conversation Antigravity interactive a été ouverte pour corriger cela avec vous.",
        "color": 15158332,
        "fields": [
            {"name": "Écarts Détectés", "value": drift_list[:1024], "inline": False},
            {"name": "Conversation Antigravity", "value": f"```{conv_id}```", "inline": True},
            {"name": "Projet Web UI", "value": "mgmt-devops", "inline": True},
            {"name": "Plan Local", "value": "`doc_drift_plan.md` à la racine du dépôt", "inline": False},
            {"name": "Action Requise", "value": "Ouvrez **https://antigravity.google.com** -> Antigravity Remote Control (`mgmt-devops`), ouvrez cette conversation et répondez pour valider/ajuster la mise à jour.", "inline": False}
        ],
        "footer": {"text": "Doc-vs-Live Coherence Auditor • CT 900 • #monitoring"},
        "timestamp": ts
    }]
}
req = urllib.request.Request(webhook_url, data=json.dumps(payload).encode("utf-8"), headers={"Content-Type": "application/json", "User-Agent": "Homelab-DocAudit/1.0"})
try:
    urllib.request.urlopen(req)
except Exception as e:
    print(f"Discord delivery error: {e}", file=sys.stderr)
EOF
fi

exit 1
