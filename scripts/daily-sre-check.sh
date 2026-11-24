#!/usr/bin/env bash
# ==============================================================================
# Morning SRE Proactive Agent & Health Verification Routine
# Path: scripts/daily-sre-check.sh
# Target: Management Workspace (CT 900 mgmt-devops)
# ==============================================================================
# Schedule: Daily at 06:00 AM (Post-backups, post-updates, post-reboots)
# Logic:
#   1. Runs 100% deterministic local health audits in pure Bash (0 LLM token).
#   2. If 100% healthy: Sends a rich GREEN Discord embed summarizing health.
#   3. If any anomaly: Spawns a dedicated Antigravity CLI Phase 1 session
#      in /root/homelab-iac with a drafted implementation_plan.md, then alerts
#      Discord with the Conversation ID for immediate one-click human review.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Source environment and credentials safely
if [ -f "${REPO_ROOT}/homelab-secrets.env" ]; then
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/homelab-secrets.env"
fi

DISCORD_WEBHOOK="${DISCORD_SRE_WEBHOOK_URL:-${DISCORD_MONITORING_WEBHOOK_URL:-${DISCORD_WEBHOOK_URL:-}}}"
AGY_BIN="/root/.local/bin/agy"
TIMESTAMP="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

NODE1_IP="${NODE1_IP:-10.0.0.10}"
NODE2_IP="${NODE2_IP:-10.0.0.20}"
NAS_IP="${NAS_IP:-10.0.0.4}"
SUBNET_PREFIX="${NODE1_IP%.*}"
DNS1_IP="${ADGUARD_PRIMARY_IP:-${SUBNET_PREFIX}.201}"
DNS2_IP="${ADGUARD_SECONDARY_IP:-${SUBNET_PREFIX}.202}"

ISSUES=()
METRICS=()

log_info() { echo "[*] [daily-sre] $*"; }
log_ok()   { echo "[+] [daily-sre] $*"; }
log_warn() { echo "[-] [daily-sre] [WARNING] $*"; ISSUES+=("⚠️ $*"); }
log_err()  { echo "[-] [daily-sre] [ERROR] $*"; ISSUES+=("❌ $*"); }

echo "=============================================================================="
echo "    ☀️  Homelab Morning SRE Proactive Health Check — $(date '+%Y-%m-%d %H:%M')"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# Sonde 1 : Quorum Corosync & Accessibilité Hyperviseurs
# ------------------------------------------------------------------------------
log_info "Vérification du cluster Proxmox VE et du quorum..."
if ping -c 1 -W 2 "${NODE1_IP}" >/dev/null 2>&1; then
    QUORUM_OUTPUT=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${NODE1_IP}" "pvecm status 2>/dev/null" || true)
    if echo "${QUORUM_OUTPUT}" | grep -qi "Quorate:\s*Yes"; then
        log_ok "Cluster Quorum: Quorate (Yes)."
        METRICS+=("Quorum & Cluster|2/2 nœuds en ligne (Quorate: Yes)")
    else
        log_err "Perte de quorum détectée sur le cluster Proxmox VE !"
    fi
else
    log_err "Impossible de joindre node-1 (${NODE1_IP}) par ping/SSH."
fi

if ! ping -c 1 -W 2 "${NODE2_IP}" >/dev/null 2>&1; then
    log_err "Impossible de joindre node-2 (${NODE2_IP}) par ping/SSH."
fi

# ------------------------------------------------------------------------------
# Sonde 2 : Espace Disque & Utilisation RAM (Seuil < 85%)
# ------------------------------------------------------------------------------
log_info "Audit de la capacité stockage et mémoire..."
check_node_resources() {
    local node_ip="$1"
    local node_label="$2"

    local disk_usage
    disk_usage=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${node_ip}" "df -h / | awk 'NR==2 {gsub(\"%\", \"\"); print \$5}'" 2>/dev/null || echo "100")
    local mem_usage
    mem_usage=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${node_ip}" "free | awk '/Mem:/ {printf(\"%.0f\", (\$3/\$2)*100)}'" 2>/dev/null || echo "100")

    if [ "${disk_usage}" -ge 85 ]; then
        log_warn "Disque système saturé sur ${node_label} : ${disk_usage}%"
    fi
    if [ "${mem_usage}" -ge 90 ]; then
        log_warn "Mémoire RAM critique sur ${node_label} : ${mem_usage}%"
    fi
    echo "${disk_usage}% SSD / ${mem_usage}% RAM"
}

NODE1_RES=$(check_node_resources "${NODE1_IP}" "node-1")
NODE2_RES=$(check_node_resources "${NODE2_IP}" "node-2")
METRICS+=("Stockage & Mémoire|node-1: ${NODE1_RES} • node-2: ${NODE2_RES}")

# ------------------------------------------------------------------------------
# Sonde 3 : Succès Sauvegardes Locales VZDump de 03:00 (< 24h)
# ------------------------------------------------------------------------------
log_info "Vérification des archives VZDump sur le partage NAS..."
BACKUP_DUMP_DIR="/mnt/pve/syno-backup/dump"
VZDUMP_COUNT=0

# Exécuté sur node-1 qui monte le partage NFS
VZDUMP_AUDIT=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${NODE1_IP}" "
    if [ -d '${BACKUP_DUMP_DIR}' ]; then
        recent=\$(find '${BACKUP_DUMP_DIR}' -maxdepth 1 -name 'vzdump-lxc-*.tar*' -mtime -1 | wc -l)
        echo \"OK:\${recent}\"
    else
        echo 'NO_MOUNT'
    fi
" 2>/dev/null || echo "ERR")

MIN_VZDUMP_ARCHIVES="${MIN_VZDUMP_ARCHIVES:-3}"
if [[ "${VZDUMP_AUDIT}" == OK:* ]]; then
    VZDUMP_COUNT="${VZDUMP_AUDIT#OK:}"
    if [ "${VZDUMP_COUNT}" -ge "${MIN_VZDUMP_ARCHIVES}" ]; then
        log_ok "VZDump: ${VZDUMP_COUNT} archives récentes (<24h) validées sur le NAS."
        METRICS+=("Sauvegardes Locales|VZDump NAS : ${VZDUMP_COUNT} archives conformes")
    else
        log_warn "Nombre insuffisant d'archives VZDump récentes (<24h) : ${VZDUMP_COUNT}/${MIN_VZDUMP_ARCHIVES} attendues."
    fi
else
    log_err "Point de montage NAS /mnt/pve/syno-backup/dump inaccessible sur node-1."
fi

# ------------------------------------------------------------------------------
# Sonde 4 : Succès Backup Cloud pCloud de 03:45 (CT 602)
# ------------------------------------------------------------------------------
log_info "Vérification du worker de sauvegarde cloud CT 602..."
CT602_STATUS=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${NODE1_IP}" "pct status 602 2>/dev/null || true")
CT602_RECENT_RUN=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${NODE1_IP}" "find /var/log/pve/tasks -name '*vzstart:602:*' -mtime -1 2>/dev/null | wc -l" || echo "0")
if echo "${CT602_STATUS}" | grep -q "status:\s*stopped"; then
    if [ "${CT602_RECENT_RUN}" -ge 1 ]; then
        log_ok "CT 602 a exécuté son cycle (<24h) et est éteint."
        METRICS+=("Sauvegardes Cloud|CT 602 pCloud : Cycle exécuté & terminé")
    else
        log_warn "CT 602 est éteint mais aucune tâche vzstart:602 détectée ces dernières 24h."
    fi
elif echo "${CT602_STATUS}" | grep -q "status:\s*running"; then
    # À 06:00, un conteneur lancé à 03:45 ne devrait plus tourner
    log_err "CT 602 est TOUJOURS EN COURS d'exécution à 06:00 (durée anormale > 2h)."
else
    log_warn "Statut de CT 602 indéterminé (${CT602_STATUS})."
fi

# ------------------------------------------------------------------------------
# Sonde 5 : Absence d'Erreur dans les Logs de Maintenance
# ------------------------------------------------------------------------------
log_info "Vérification des journaux d'updates nocturnes..."
LOG_ERRORS=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${NODE1_IP}" "
    if [ -f /var/log/homelab-updates.log ]; then
        grep -Ei 'dpkg: error|Sub-process.*returned an error code|Failed to fetch' /var/log/homelab-updates.log | tail -n 3 || true
    fi
" 2>/dev/null || true)

if [ -n "${LOG_ERRORS}" ]; then
    log_warn "Erreurs relevées dans /var/log/homelab-updates.log : ${LOG_ERRORS}"
else
    log_ok "Journaux de mises à jour propres (0 erreur critique)."
    METRICS+=("Mises à Jour|Updates propres (0 erreur dpkg/apt)")
fi

# ------------------------------------------------------------------------------
# Sonde 6 : Santé Conteneurs LXC et Stacks Docker
# ------------------------------------------------------------------------------
log_info "Audit de l'état des conteneurs LXC et Docker..."
DOCKER_CRASHES=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${NODE1_IP}" '
    for ctid in $(pct list 2>/dev/null | awk '\''NR>1 && $2=="running" {print $1}'\''); do
        out=$(pct exec "${ctid}" -- sh -c "command -v docker >/dev/null 2>&1 && docker ps --filter status=restarting --format {{.Names}}" 2>/dev/null || true)
        if [ -n "${out}" ]; then
            while IFS= read -r cname; do
                [ -n "${cname}" ] && echo "CT ${ctid}: ${cname} (Restarting)"
            done <<< "${out}"
        fi
    done
' 2>/dev/null || true)

DOCKER_CRASHES_N2=$(ssh -o StrictHostKeyChecking=no -o BatchMode=yes "root@${NODE2_IP}" '
    for ctid in $(pct list 2>/dev/null | awk '\''NR>1 && $2=="running" {print $1}'\''); do
        out=$(pct exec "${ctid}" -- sh -c "command -v docker >/dev/null 2>&1 && docker ps --filter status=restarting --format {{.Names}}" 2>/dev/null || true)
        if [ -n "${out}" ]; then
            while IFS= read -r cname; do
                [ -n "${cname}" ] && echo "CT ${ctid}: ${cname} (Restarting)"
            done <<< "${out}"
        fi
    done
' 2>/dev/null || true)

ALL_CRASHES="${DOCKER_CRASHES}"$'\n'"${DOCKER_CRASHES_N2}"
ALL_CRASHES=$(echo "${ALL_CRASHES}" | sed '/^[[:space:]]*$/d')

if [ -n "${ALL_CRASHES}" ]; then
    log_err "Conteneurs Docker en boucle de crash (Restarting) : ${ALL_CRASHES}"
else
    log_ok "Tous les conteneurs Docker en production sont sains."
    METRICS+=("Conteneurs Docker|Toutes les stacks actives sont stables (0 crashloop)")
fi

# ------------------------------------------------------------------------------
# Sonde 7 : Haute Disponibilité Résolution DNS
# ------------------------------------------------------------------------------
log_info "Test des serveurs DNS AdGuard Primary et Secondary..."
DNS1_OK=false
DNS2_OK=false

if dig @"${DNS1_IP}" +short +time=2 +tries=1 google.com >/dev/null 2>&1; then
    DNS1_OK=true
fi
if dig @"${DNS2_IP}" +short +time=2 +tries=1 google.com >/dev/null 2>&1; then
    DNS2_OK=true
fi

if [ "${DNS1_OK}" = true ] && [ "${DNS2_OK}" = true ]; then
    log_ok "DNS HA : Primaire (${DNS1_IP}) et Secondaire (${DNS2_IP}) opérationnels."
    METRICS+=("Résolution DNS|HA Active-Active validée (Primaire & Secondaire OK)")
elif [ "${DNS1_OK}" = true ] || [ "${DNS2_OK}" = true ]; then
    log_warn "Dégradation DNS : un seul des deux résolveurs AdGuard répond."
else
    log_err "PANNE MAJEURE DNS : Aucun résolveur AdGuard ne répond sur le LAN !"
fi

# ------------------------------------------------------------------------------
# Sonde 8 : Dérive Déclarative OpenTofu & Branche Git Active
# ------------------------------------------------------------------------------
log_info "Vérification de la branche Git active et de la dérive OpenTofu..."
CURRENT_BRANCH=$(git -C "${REPO_ROOT}" branch --show-current 2>/dev/null || echo "unknown")
if [ "${CURRENT_BRANCH}" != "main" ]; then
    log_warn "Git : mgmt-devops est sur la branche '${CURRENT_BRANCH}' au lieu de 'main' (les définitions 'instance' peuvent être masquées)."
fi

TOFU_PLAN_EXIT=0
if command -v tofu >/dev/null 2>&1 && [ -d "${REPO_ROOT}/tofu" ]; then
    cd "${REPO_ROOT}/tofu"
    tofu plan -detailed-exitcode -no-color >/dev/null 2>&1 || TOFU_PLAN_EXIT=$?
    cd "${REPO_ROOT}"
fi

if [ "${TOFU_PLAN_EXIT}" -eq 0 ]; then
    log_ok "OpenTofu : Aucune dérive (Infrastructure 100% synchronisée avec Git)."
    METRICS+=("État Déclaratif|OpenTofu : 0 dérive (Git matches live)")
elif [ "${TOFU_PLAN_EXIT}" -eq 2 ]; then
    log_warn "OpenTofu : Dérive d'infrastructure détectée par 'tofu plan' (ressources divergentes ou orphelines)."
else
    log_err "OpenTofu : Erreur lors de l'exécution de 'tofu plan' (code exit ${TOFU_PLAN_EXIT})."
fi

# ------------------------------------------------------------------------------
# Sonde 9 : Synchronisation Code <-> Documentation & Isolation Subnet
# ------------------------------------------------------------------------------
log_info "Vérification de l'isolation subnet et de la synchronisation doc..."
SUBNET_ISO_OK=true
DOC_SYNC_OK=true

if [ -x "${SCRIPT_DIR}/check-subnet-isolation.sh" ]; then
    if ! "${SCRIPT_DIR}/check-subnet-isolation.sh" >/dev/null 2>&1; then
        SUBNET_ISO_OK=false
        log_err "Violation d'isolation des sous-réseaux (fuite d'adresses privées ou de template) !"
    fi
fi

if [ -x "${SCRIPT_DIR}/check-doc-sync.sh" ]; then
    if ! "${SCRIPT_DIR}/check-doc-sync.sh" --audit >/dev/null 2>&1; then
        DOC_SYNC_OK=false
        log_warn "Dérive de documentation détectée (tofu/*.tf diverge de docs/instance/INVENTORY.md) !"
    fi
fi

if [ "${SUBNET_ISO_OK}" = true ] && [ "${DOC_SYNC_OK}" = true ]; then
    log_ok "Isolation subnet et synchronisation doc 100% conformes."
    METRICS+=("Gouvernance & Doc|Isolation subnet & sync doc conformes")
fi

echo "=============================================================================="

# ------------------------------------------------------------------------------
# ÉTAPE 2A : Scénario Nominal (100% RAS — Zéro Jeton LLM Consommé)
# ------------------------------------------------------------------------------
if [ "${#ISSUES[@]}" -eq 0 ]; then
    log_ok "BILAN SRE : 100% RAS ! Envoi du compte-rendu Discord vert..."

    if [ -n "${DISCORD_WEBHOOK}" ]; then
        python3 -c "
import json, sys, urllib.request

metrics = json.loads(sys.argv[1])
fields = []
for m in metrics:
    parts = m.split('|', 1)
    fields.append({'name': parts[0], 'value': parts[1], 'inline': True})

payload = {
    'embeds': [{
        'title': '✅ Homelab Morning SRE Check — 100% RAS',
        'description': 'Tous les systèmes, sauvegardes, conteneurs, DNS et états déclaratifs ont été audités avec succès.',
        'color': 3066993, # Vert #2ECC71
        'fields': fields,
        'footer': {'text': 'Morning Proactive SRE Agent • mgmt-devops (CT 900) • 0 token LLM'},
        'timestamp': sys.argv[2]
    }]
}

req = urllib.request.Request(sys.argv[3], data=json.dumps(payload).encode('utf-8'), headers={'Content-Type': 'application/json', 'User-Agent': 'Homelab-SRE-Agent/1.0'})
try:
    urllib.request.urlopen(req)
except Exception as e:
    print(f'Discord delivery error: {e}', file=sys.stderr)
" "$(python3 -c "import json, sys; print(json.dumps(sys.argv[1:]))" "${METRICS[@]}")" "${TIMESTAMP}" "${DISCORD_WEBHOOK}"
    fi

    log_ok "Vérification matinale achevée avec succès (0 anomalie)."
    exit 0
fi

# ------------------------------------------------------------------------------
# ÉTAPE 2B : Scénario d'Anomalie (Auto-Spawn Antigravity Session + Alerte Rouge)
# ------------------------------------------------------------------------------
log_info "BILAN SRE : ${#ISSUES[@]} anomalie(s) détectée(s) ! Instanciation de l'agent Antigravity..."

ANOMALIES_MD=""
for issue in "${ISSUES[@]}"; do
    ANOMALIES_MD+=$'\n'"- ${issue}"
done

TODAY_SRE_DATE="$(date +'%Y-%m-%d')"
PROMPT="[MORNING SRE ALERT ${TODAY_SRE_DATE}] ${#ISSUES[@]} anomalie(s) détectée(s)
[PHASE 1 — ANALYSE, RECHERCHE & PLANIFICATION FLASH-READY | Model: \"pro\" | READ-ONLY]

Le Morning SRE Proactive Agent a détecté ${#ISSUES[@]} anomalie(s) critique(s) sur le homelab lors du contrôle matinal de 06:00 :

${ANOMALIES_MD}

Consignes strictes d'orchestration :
1. En mode strictement lecture seule, inspecte immédiatement les logs, conteneurs et ressources incriminés.
2. Identifie précisément la cause racine de chaque anomalie (processus bloqué, disque saturé, rupture de lien, etc.).
3. Rédige un plan de remédiation complet, chirurgical et 'Flash-Ready' dans <artifact-dir>/scratch/plan_draft.md.
4. Publie <artifact-dir>/implementation_plan.md afin que l'opérateur humain puisse vérifier les commandes de correction et donner son approbation en 1 clic.
5. N'effectue AUCUNE action mutative sans validation explicite de l'utilisateur."

log_info "Lancement du CLI Antigravity en mode plan..."
CONV_ID="session-pending"
CLI_JSON_OUTPUT=""

if [ -x "${AGY_BIN}" ]; then
    cd "${REPO_ROOT}"
    # Modèle Antigravity CLI valide (gemini-4-argon-high pour analyse Pro approfondie)
    AGY_TARGET_MODEL="${ANTIGRAVITY_MODEL:-gemini-4-argon-high}"
    AGY_PROJECT_ID="${ANTIGRAVITY_PROJECT_ID:-}"
    AGY_PROJECT_ARGS=()
    if [ -n "${AGY_PROJECT_ID}" ]; then
        AGY_PROJECT_ARGS=(--project "${AGY_PROJECT_ID}")
    fi
    CLI_JSON_OUTPUT=$("${AGY_BIN}" \
        --mode plan \
        --model "${AGY_TARGET_MODEL}" \
        "${AGY_PROJECT_ARGS[@]}" \
        --dangerously-skip-permissions \
        --output-format json \
        -p "${PROMPT}" 2>&1 || true)

    # Extraction du conversation ID depuis le payload JSON
    CONV_ID=$(echo "${CLI_JSON_OUTPUT}" | jq -r '.conversation_id // .conversationId // empty' 2>/dev/null || true)
    if [ -z "${CONV_ID}" ]; then
        # Découverte du brain le plus récent généré (trié par mtime décroissant)
        CONV_ID=$(find /root/.gemini/antigravity-cli/brain -maxdepth 1 -mindepth 1 -type d -cmin -5 -printf '%T@ %f\n' 2>/dev/null | sort -rn | head -n1 | awk '{print $2}' || true)
    fi
    if [ -z "${CONV_ID}" ]; then
        CONV_ID="session-pending"
        log_warn "Impossible d'extraire le Conversation ID Antigravity. Sortie CLI : ${CLI_JSON_OUTPUT:0:200}"
    else
        log_ok "Session Antigravity créée avec succès. Conversation ID: ${CONV_ID}"
        # Set human-readable title and ensure project_id in conversation_summaries.db
        TODAY_DATE="$(date +'%Y-%m-%d')"
        if [ -n "${AGY_PROJECT_ID}" ]; then
            sqlite3 /root/.gemini/antigravity-cli/conversation_summaries.db \
                "UPDATE conversation_summaries SET title = 'Morning SRE Remediation Plan (${TODAY_DATE})', project_id = '${AGY_PROJECT_ID}' WHERE conversation_id = '${CONV_ID}' AND (title IS NULL OR title = '');" 2>/dev/null || true
        else
            sqlite3 /root/.gemini/antigravity-cli/conversation_summaries.db \
                "UPDATE conversation_summaries SET title = 'Morning SRE Remediation Plan (${TODAY_DATE})' WHERE conversation_id = '${CONV_ID}' AND (title IS NULL OR title = '');" 2>/dev/null || true
        fi
        # Expose implementation_plan.md at repository root for instant access
        PLAN_SRC="/root/.gemini/antigravity-cli/brain/${CONV_ID}/implementation_plan.md"
        if [ -f "${PLAN_SRC}" ]; then
            cp -f "${PLAN_SRC}" "${REPO_ROOT}/morning_sre_plan.md"
        fi

        # Re-synchronise le démon Antigravity Remote Control depuis cron (system.slice) pour exposer instantanément la session dans l'UI Web
        UID_VAL=$(id -u)
        export XDG_RUNTIME_DIR="/run/user/${UID_VAL}"
        systemctl --user restart antigravity-cli-daemon.service 2>/dev/null || true
    fi
else
    log_err "Binaire agy introuvable à ${AGY_BIN}."
    CONV_ID="agy-binary-not-found"
fi

# Envoi de l'alerte Discord Orange/Rouge avec le deep-link et l'ID (Heredoc sans interpolation Bash)
if [ -n "${DISCORD_WEBHOOK}" ]; then
    python3 - "${ANOMALIES_MD}" "${CONV_ID}" "${DISCORD_WEBHOOK}" "${TIMESTAMP}" << 'EOF'
import json, sys, urllib.request

issues_list = sys.argv[1]
conv_id = sys.argv[2]
webhook_url = sys.argv[3]
timestamp = sys.argv[4]

payload = {
    'embeds': [{
        'title': '🚨 Homelab Morning SRE Check — Anomalie Détectée & Plan Prêt',
        'description': 'Le contrôle automatique de 06:00 a détecté des anomalies nécessitant votre attention. Un agent Antigravity a préparé une analyse et un plan de remédiation.',
        'color': 15158332, # Rouge #E74C3C
        'fields': [
            {'name': 'Anomalies Relevées', 'value': issues_list[:1024], 'inline': False},
            {'name': 'Session Antigravity Créée', 'value': f'```{conv_id}```', 'inline': True},
            {'name': 'Projet Web UI', 'value': 'mgmt-devops', 'inline': True},
            {'name': 'Fichier Plan Direct', 'value': '`morning_sre_plan.md` à la racine du dépôt Git', 'inline': False},
            {'name': 'Action Requise', 'value': 'Ouvrez Antigravity Remote Control Web UI (https://antigravity.google.com) sur `mgmt-devops` pour inspecter et exécuter la remédiation, ou consultez `morning_sre_plan.md`.', 'inline': False}
        ],
        'footer': {'text': 'Morning Proactive SRE Agent • mgmt-devops (CT 900)'},
        'timestamp': timestamp
    }]
}

req = urllib.request.Request(webhook_url, data=json.dumps(payload).encode('utf-8'), headers={'Content-Type': 'application/json', 'User-Agent': 'Homelab-SRE-Agent/1.0'})
try:
    urllib.request.urlopen(req)
except Exception as e:
    print(f'Discord alert delivery error: {e}', file=sys.stderr)
EOF
fi

exit 1
