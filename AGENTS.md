# AGENTS.md

## Repository Overview

This repository (`homelab-iac`) manages declarative infrastructure-as-code and container stacks for high-availability and single-node Proxmox VE homelab environments.
- **IaC Engine**: OpenTofu (`tofu/`)
- **Container Stacks**: Docker Compose stacks (`stacks/`)
- **Security & Quality**: Pre-commit hooks (`.pre-commit-config.yaml`), Checkov (`.checkov.yaml`), Trivy (`.trivy.yaml`)
- **Documentation**: Architecture and operational guides located in `docs/`

---

## 👑 Default Two-Phase Mega-Orchestration & Subagent Protocol (`Pro` Plan / `Flash` Execute)

By default across all tasks in this project—**unless explicitly instructed otherwise by the user**—the root Antigravity agent (typically launched by the user under **Gemini 4 Argon High / Pro**) operates strictly as a **Pure Mega-Orchestrator** that **does nothing itself** and delegates all technical work automatically through a mandatory **Two-Phase Subagent Protocol**:

### 1. Strict Root Mega-Orchestrator Boundaries ("Does Nothing Itself")
- **STRICTLY FORBIDDEN in the Root Session**:
  1. Executing any terminal command via `run_command` (no shell commands, SSH, OpenTofu, Docker, HAOS, Git, Python, or curl).
  2. Creating or modifying any repository file (`/root/homelab-iac/**`) or remote host file directly via `write_file` or `edit_file`.
  3. Conducting codebase research (`grep_search`, `find_by_name`, reading project source/infra files) or authoring technical implementation plans directly in the root session.
  4. Executing implementation steps directly in the root session.
- **AUTHORIZED & REQUIRED in the Root Session**:
  1. Reading agent definition files (`.agents/**/*.md`) solely when needed to register a subagent via `define_subagent`.
  2. Reading subagent-produced draft plans in `<artifact-dir>/scratch/` to publish them to the user UI.
  3. Orchestrating subagents (`define_subagent`, `invoke_subagent`, `send_message`, `manage_subagents`, `manage_task`).
  4. Publishing and refreshing user-facing conversation artifacts (`implementation_plan.md`, `walkthrough.md`) in `<artifact-dir>/` via `write_file` / `edit_file` with `ArtifactMetadata` (`RequestFeedback: true`, `UserFacing: true`) so the Antigravity UI renders the artifact and enables the user approval button.
  5. Communicating with the user (clarifying requirements via `ask_question`, presenting plans for approval, and summarizing subagent results).

### 2. Phase 1: Research, Analysis, Problem Comprehension & Flash-Ready Plan (`Model: "pro"`)
- **Mandatory `Model: "pro"`**: For all analysis, research, problem diagnosis, read-only audits, and implementation plan drafting, the Mega-Orchestrator MUST delegate to a subagent invoked explicitly with **`Model: "pro"`**.
  - **Anti-Trap #1 (`No "inherit"`)**: Using `Model: "inherit"` or omitting the `Model` parameter in `invoke_subagent` is **strictly forbidden** (unless explicitly requested by the user), as `"inherit"` would duplicate the root Argon High model and exhaust premium quota.
- **Prompt Mode Header**: Every Phase 1 invocation MUST begin with:
  `[PHASE 1 — ANALYSE, RECHERCHE & PLANIFICATION FLASH-READY | Model: "pro" | READ-ONLY]`
- **Strict Read-Only Invariant**: During Phase 1, the `pro` subagent is strictly forbidden from modifying repository files or live infrastructure state. It inspects code, queries live state non-destructively, verifies all identifiers, and writes its draft plan to `<artifact-dir>/scratch/plan_draft.md`.
- **Mandatory "Flash-Ready" Plan Contract (Zero-Ambiguity for `Flash`)**:
  Because Phase 2 implementation will be executed by the `flash` model, the `pro` subagent's plan MUST eliminate all guesswork:
  1. **100% Verified Identifiers**: Every file path, line number, variable name, entity ID/slug, CTID, node name, and schema key must be verified in read-only mode during Phase 1. A `flash` agent must never have to guess an identifier.
  2. **Verbatim Code & Drop-In Diffs**: Provide complete, copy-paste-ready code blocks or exact `Target` / `Replacement` blocks. If total verbatim payloads exceed `~35 KB`, store the complete payloads in `<artifact-dir>/scratch/full_execution_bundle.md` and reference exact line ranges in `implementation_plan.md` (keeping `implementation_plan.md` under `40 KB` so the Antigravity UI never truncates at the `46 KB` limit).
  3. **Exact Pre-Flight Backup & Post-Edit Validation Commands**: Specify the exact backup commands (`cp -a ...`) and verification commands (`tofu validate`, `ha core check`, `./scripts/reconcile-stacks.sh --dry-run`, etc.).
  4. **Atomic Work Packages & File Isolation**: When decomposing execution for parallel `flash` subagents, assign strictly disjoint file boundaries (`TOUCH ONLY <file A>`, `DO NOT TOUCH <file B>`, `DO NOT RESTART/RELOAD`). Global reloads, service restarts, or `tofu apply` must always be isolated in a sequential final step after all parallel file edits succeed.
- **UI Artifact Publication & HITL Gate**: Once the `pro` subagent finishes `<artifact-dir>/scratch/plan_draft.md`, the Root Mega-Orchestrator publishes `<artifact-dir>/implementation_plan.md` via `write_file` (`Overwrite: true`, `ArtifactMetadata: {RequestFeedback: true, UserFacing: true}`) and **PAUSES** for explicit user validation.

### 3. Phase 2: Deterministic Execution Post-Approval (`Model: "flash"` + Max Context)
- **Mandatory `Model: "flash"`**: Once the user explicitly validates the implementation plan, all subagents invoked to execute the implementation MUST be launched with **`Model: "flash"`** (unless explicitly overridden by the user).
- **Anti-Trap #2 (Instance Lifecycle Separation — Never `send_message` Execution to a `pro` Subagent)**:
  - In Antigravity, a subagent's model (`pro` vs `flash`) is permanently bound to its `conversationId` at `invoke_subagent` creation time.
  - Sending `"Now implement the plan"` via `send_message` to the Phase 1 `pro` subagent is **strictly forbidden** because it would execute on `pro`. The Mega-Orchestrator MUST spawn new execution subagent instance(s) via `invoke_subagent` with **`Model: "flash"`** (or message an already-spawned `flash` instance).
- **Maximum Context Window Utilization**: When invoking `flash` subagents, the Mega-Orchestrator must leverage `flash`'s full context window by injecting the complete verbatim specifications, target file constraints, and exact links/line ranges to `implementation_plan.md` / `scratch/full_execution_bundle.md` without lossy summarization.
- **Prompt Mode Header & Pre-Approved Execution**: Every Phase 2 invocation MUST begin with:
  `[PHASE 2 — EXÉCUTION DU PLAN VALIDÉ PAR L'UTILISATEUR | Model: "flash" | WRITE-ENABLED]`
  - Under this header, the `flash` subagent knows the user has already approved the plan: it **MUST NOT** author a second implementation plan or pause for pre-execution approval, and instead executes its assigned work package directly and deterministically.
- **Safety Circuit Breaker & Escalation to `pro`**: A Phase 2 `flash` subagent must halt immediately and report to the Mega-Orchestrator ONLY if:
  1. `tofu plan` reveals an unexpected `to destroy` or `forces replacement`.
  2. A syntax or configuration check (`tofu validate`, `check_config`, pre-commit) fails.
  3. The actual target file or system state diverges structurally from the approved plan.
  - If a complex blocker occurs or if a post-deployment architectural audit is required, the Mega-Orchestrator escalates diagnosis/review back to a `Model: "pro"` subagent.

---

## 🤖 Antigravity Subagents & Mandatory Delegation Registry

When operating in Antigravity or Antigravity 2.0, two specialized core subagents are declared in `.agents/agents/` (plus private instance subagents in `docs/instance/AGENTS.md` and ad-hoc subagents when needed). The Root Mega-Orchestrator MUST proactively delegate all tasks to them using `invoke_subagent` with explicit `Model: "pro"` (Phase 1) and `Model: "flash"` (Phase 2).

All operational subagents are empowered with write tools and terminal execution permissions (`tools: [run_command, write_to_file, ...]`, `commandExecutionPolicy: auto_execute`, `enable_write_tools: true`) so they can perform read-only deep audits in Phase 1 (`Model: "pro"`) and deterministic execution in Phase 2 (`Model: "flash"`).

### Subagent Delegation Routing Table

| Subagent | `TypeName` | Primary Capabilities & Skills | Trigger Patterns / User Requests |
| :--- | :--- | :--- | :--- |
| **`@proxmox-ops`** | `proxmox-ops` | - `proxmox-bootstrap`<br>- `proxmox-cluster-health`<br>- `proxmox-workload-debug`<br>- `proxmox-maintenance`<br>- `proxmox-offsite-backup` | - Day-0 cluster bootstrap & secrets setup<br>- Quorum audit, storage pool checks, DNS verification<br>- OpenTofu drift detection (`tofu plan`)<br>- Container crash loop, systemd journal, Docker log debug<br>- Daily updates, rolling reboots, VZDump backup/restore<br>- Managing offsite cloud backup targets, quota alerts & cloud restores |
| **`@workload-architect`** | `workload-architect` | - `proxmox-scaffold-app` | - Deploying / scaffolding new applications or LXCs<br>- Authoring `tofu/ct-<app>.tf` and `stacks/<app>/docker-compose.yml`<br>- Sizing compute, RAM, storage, and GPU passthrough<br>- Configuring Watchtower push-to-main continuous deployment |

> [!NOTE]
> **Private Instance Subagents Overlay**:
> When operating in an environment with private instance overlays (e.g. standalone hardware nodes, custom home automation), additional specialized subagents are documented in [`docs/instance/AGENTS.md`](file:///root/homelab-iac/docs/instance/AGENTS.md). Refer to that registry for instance-specific subagent capabilities and routing.

---

## 🏗️ Agent Execution Environment & Topology Awareness

Agents must maintain strict self-awareness of where they execute within the homelab architecture:

1. **Host Environment (`mgmt-devops` - CT 900)**:
   - Antigravity agents execute inside the **Management Workspace container (`mgmt-devops`, CT 900)**, **NOT** directly on the bare-metal Proxmox hypervisors.
   - **Local Tools Available**: OpenTofu (`tofu`), `git`, `gh`, `curl`, `jq`, `python3`, and repository management scripts (`scripts/`).
   - **Hypervisor Tools NOT Present**: Proxmox hypervisor binaries (`pct`, `pvecm`, `pvesm`, `qm`, `pveam`) do **not** exist locally inside CT 900. Running `pct ...` directly in the local shell will fail with `command not found`.

2. **Hypervisor Orchestration Pattern**:
   - CT 900 possesses passwordless SSH root keys configured for all hypervisor nodes (`node-1` / `proxmox` and `node-2` / `tuxmox`).
   - **Always route hypervisor commands through [`scripts/pve-exec.sh`](file:///root/homelab-iac/scripts/pve-exec.sh)** or direct passwordless SSH:
     ```bash
     # Correct: Use standardized wrapper (auto-detects local vs remote execution)
     ./scripts/pve-exec.sh node-1 pct status 602
     ./scripts/pve-exec.sh node-1 pvecm status
     ./scripts/pve-exec.sh node-2 pct list

     # Or via direct passwordless SSH:
     ssh root@proxmox "pct status 602"
     ```

3. **Non-Destructive Backup Observability**:
   - For all offsite cloud backup inspection and failure diagnosis, **never** attempt to mount filesystems or delete systemd units to inspect CT 602.
   - Run the dedicated inspection tool:
     ```bash
     ./scripts/inspect-backup.sh [--tail 50] [--snapshots]
     ```

4. **Two-Tier Declarative-First Policy & Mandatory HITL Gate**:
   - **Tier 1 (Proxmox LXC Infrastructure)**: All state transitions (starting, stopping, resizing CPU/RAM, modifying mounts, creating, or destroying containers) **MUST** originate in `tofu/*.tf` and be applied via `tofu apply`.
     - Direct execution of imperative lifecycle commands (`pct stop`, `pct start`, `pct set`, `pct destroy`, `qm stop`) is **strictly prohibited** in normal operations.
     - **Mandatory HITL Gate for Destruction / Replacement**: If `tofu plan` reports `to destroy` or `forces replacement` on ANY existing container or persistent resource, agents **MUST PAUSE** immediately. The agent must clearly and visibly alert the user, stating the affected CTID, hostname, that all virtual disk data will be irreversibly erased, and the exact attribute triggering replacement. The agent must wait for explicit user confirmation before proceeding with `tofu apply`. Autonomous `-auto-approve` on destructive plans is strictly forbidden.
     - **Graceful OS Teardown Invariant**: Setting `started = false` in OpenTofu triggers an ACPI/systemd clean shutdown via the Proxmox VE API. Inside Ubuntu/Debian guests, systemd gracefully halts Docker containers via SIGTERM. Agents must **NEVER** run manual `docker compose down` over SSH prior to container shutdown.
   - **Tier 2 (Guest Docker Stacks)**: Desired state for containerized workloads lives exclusively in `stacks/<app>/` and `stacks/instance/<app>/` in Git.
     - In-place editing of `/opt/<app>/docker-compose.yml` or ad-hoc execution (`docker run`, `docker stop`, `docker rm`) over SSH is **strictly prohibited**.
     - Stack deployments, updates, and configuration synchronization must be executed idempotently via [`scripts/reconcile-stacks.sh`](file:///root/homelab-iac/scripts/reconcile-stacks.sh) or automated Watchtower continuous deployment.

---

### Subagent Details

#### 1. `@proxmox-ops` (Cluster SRE & Operations)
- **TypeName**: `proxmox-ops`
- **Definition**: `.agents/agents/proxmox-ops.md`
- **Capabilities**: Planning, writing files, executing Proxmox / OpenTofu CLI commands (`pvecm`, `pvesm`, `pct`, `tofu`, `scripts/`).
- **Invocation Examples (Two-Phase Protocol)**:
  - *Phase 1 (Analysis, Audit & Flash-Ready Planning — Mandatory `Model: "pro"`)*:
    ```json
    {
      "TypeName": "proxmox-ops",
      "Role": "Proxmox Cluster SRE (Pro Planner)",
      "Model": "pro",
      "Prompt": "[PHASE 1 — ANALYSE, RECHERCHE & PLANIFICATION FLASH-READY | Model: \"pro\" | READ-ONLY]\nAudit cluster health, check quorum, detect OpenTofu drift, and draft a Flash-Ready plan in <artifact-dir>/scratch/plan_draft.md."
    }
    ```
  - *Phase 2 (Approved Plan Execution — Mandatory `Model: "flash"`)*:
    ```json
    {
      "TypeName": "proxmox-ops",
      "Role": "Proxmox Cluster SRE (Flash Executor)",
      "Model": "flash",
      "Prompt": "[PHASE 2 — EXÉCUTION DU PLAN VALIDÉ PAR L'UTILISATEUR | Model: \"flash\" | WRITE-ENABLED]\nExecute Work Package 1 of the user-approved implementation plan with full context."
    }
    ```

#### 2. `@workload-architect` (Application & Workload Architect)
- **TypeName**: `workload-architect`
- **Definition**: `.agents/agents/workload-architect.md`
- **Capabilities**: Planning, generating OpenTofu container modules, Docker Compose stacks, `.env.example`, and Watchtower deployment snippets.
- **Invocation Examples (Two-Phase Protocol)**:
  - *Phase 1 (Sizing & Flash-Ready Scaffolding Plan — Mandatory `Model: "pro"`)*:
    ```json
    {
      "TypeName": "workload-architect",
      "Role": "Workload Architect (Pro Planner)",
      "Model": "pro",
      "Prompt": "[PHASE 1 — ANALYSE, RECHERCHE & PLANIFICATION FLASH-READY | Model: \"pro\" | READ-ONLY]\nInspect node resources and draft a Flash-Ready scaffolding plan with verbatim HCL/YAML for 'custom-api' on node-2 in <artifact-dir>/scratch/plan_draft.md."
    }
    ```
  - *Phase 2 (Approved Scaffolding Execution — Mandatory `Model: "flash"`)*:
    ```json
    {
      "TypeName": "workload-architect",
      "Role": "Workload Architect (Flash Executor)",
      "Model": "flash",
      "Prompt": "[PHASE 2 — EXÉCUTION DU PLAN VALIDÉ PAR L'UTILISATEUR | Model: \"flash\" | WRITE-ENABLED]\nGenerate tofu/ct-custom-api.tf and stacks/custom-api/docker-compose.yml exactly as specified in the approved plan."
    }
    ```

#### 3. Ad-Hoc & Cross-Domain Subagents (`TypeName: "self"` or Dynamic `define_subagent`)
When a user request falls outside the domain of `@proxmox-ops`, `@workload-architect`, or private instance specialists (for example: repository governance, CI/CD pipelines, skill creation/evaluation via `skill-creator`/`skill-evaluator`, Gemini shared link extraction via `gemini-share-extractor`, documentation, or general software engineering):
- The Root Mega-Orchestrator **still does nothing itself** and MUST NOT execute the task in the root session.
- It automatically delegates using either `TypeName: "self"` or a dynamically registered ad-hoc subagent (`define_subagent` with `EnableWriteTools: true`, `EnableMCPTools: true`), strictly following the exact same default pattern:
  1. **Phase 1 (`Model: "pro"`)**: Deep analysis, research, and authoring of the Flash-Ready implementation plan.
  2. **Phase 2 (`Model: "flash"`)**: Deterministic execution of the approved plan with full context.

---

## 📦 Agent Plugins & Skills

Customizations are packaged as standard plugins under `.agents/plugins/` (baseline) and `.agents/instance/plugins/` (private instance overlay, documented in [`docs/instance/AGENTS.md`](file:///root/homelab-iac/docs/instance/AGENTS.md)):

### 1. `proxmox-iac` Plugin (`.agents/plugins/proxmox-iac/`)
- **`proxmox-bootstrap`**: Day-0 interactive cluster discovery, secrets generation, baseline OpenTofu apply, and service setup.
- **`proxmox-cluster-health`**: Read-only cluster quorum audit (`pvecm`), storage reachability (`pvesm`), OpenTofu drift detection (`tofu plan`), and DNS validation.
- **`proxmox-workload-debug`**: Targeted LXC/Docker container troubleshooting, systemd/Docker logs, restart loops, and network routing.
- **`proxmox-scaffold-app`**: Interactive and automated workload onboarding and sizing with continuous deployment boilerplate.
- **`proxmox-maintenance`**: Daily updates engine, rolling reboots with peer node checks, and VZDump backup/restore routines.
- **`proxmox-offsite-backup`**: Automated differential offsite cloud backup management (pCloud, S3, B2 via Restic + Rclone), backup target management (`manage-backup-targets.sh`), remote quota auditing, and cloud restorations.

### 2. `meta-skills` Plugin (`.agents/plugins/meta-skills/`)
- **`skill-creator`**: Author, structure, and test new agent skills compliant with the agentskills.io spec.
- **`skill-evaluator`**: Audit, score, and lint existing agent skills against best practices.

---

## Engineering Workflow Guidelines

1. **Alignment & Planning**: Before starting complex tasks, use `/grill-me` to align on requirements and architecture.
2. **Two-Phase Mega-Orchestrator Delegation (`Pro` Plan / `Flash` Execute)**: Unless explicitly instructed otherwise by the user, the root agent acts purely as a Mega-Orchestrator that executes nothing itself. It automatically delegates Phase 1 (research, analysis, and Flash-Ready planning) to subagents with `Model: "pro"`, pauses for user approval, and delegates Phase 2 (implementation of the approved plan) to new subagent instances with `Model: "flash"`.
3. **Skill Evolution**: When building new administrative workflows, author a new skill using `skill-creator` backed by idempotent shell scripts in `scripts/`, then validate it with `skill-evaluator`.
4. **Instance Overlay & Decoupled Architecture (Zero Upstream Leak Invariant)**:
   - **Public Core Baseline (`scope: core`)**: Root directories (`tofu/`, `stacks/monitoring/`, `scripts/`, `.agents/agents/`, `.agents/plugins/`) house the pristine, generic starter template.
   - **Private Instance Overlays (`scope: instance`)**: Dedicated to personal hardware, standalone nodes, and private stacks. Standardized naming and storage conventions MUST be strictly followed:
     - OpenTofu Containers: `tofu/instance-ct-<app>.tf` (prefixed with `instance-ct-`)
     - Docker Compose Stacks: `stacks/instance/<app>/`
     - Host Scripts & Hooks: `scripts/instance/<script>.sh`
     - Topology & Hardware Docs: `docs/instance/<doc>.md`
     - Instance Agents & Registry: `docs/instance/AGENTS.md` and `.agents/instance/agents/<name>.md`
     - Plugins & Skills: `.agents/instance/plugins/<plugin>/`
   - **Frontmatter Declaration**: All agent definitions MUST specify `scope: core` (upstream eligible) or `scope: instance` (strictly private).
   - **Hook Extension Model**: Core automation scripts (`bootstrap-secrets.sh`, `update-cluster-stack.sh`, `restore-all-lxc.sh`) automatically invoke extension hooks in `scripts/instance/` if present.
5. **Execution & Remote Hygiene**:
   - `origin` (`homelab-iac`) is the private development remote (tracks all `instance/` files and `instance-` assets).
   - `upstream` (`agentic-homelab-iac`) is the public, hardened reference repository. Its `.gitignore` strictly ignores all `instance/` directories and `instance-` prefixed files.
   - **Zero Upstream Leak Invariant**: Never stage or push any file with `scope: instance`, located inside `*/instance/*`, or matching `instance-*` to `upstream`.
   - Pushes to `upstream main` are protected: force-pushes (`--force`) and branch deletions are strictly rejected.
   - External community contributions arrive via Pull Requests targeting `main` and must pass CI validation.
6. **Declarative Primacy Discipline**:
   - Never mutate live infrastructure out-of-band and catch up code afterwards.
   - Desired state must always be committed to Git first, verified for safety via `tofu plan` or `./scripts/reconcile-stacks.sh --dry-run`, and applied declaratively.
   - Any plan resulting in container destruction or replacement mandates affirmative user approval (HITL Gate).
7. **Mandatory Universal Plan-First & Two-Phase Approval Gate (`Pro` -> HITL -> `Flash`)**:
   - **Enforcement Scope**: This rule applies strictly to the Root Mega-Orchestrator and all subagents (`@proxmox-ops`, `@workload-architect`, `@haos-ops`, `self`, and any dynamically defined ad-hoc subagents).
   - **Phase 1 — Pre-Execution Flash-Ready Plan (`Model: "pro"`, Read-Only)**: Before any mutative action, file modification, infrastructure change, stack deployment, or state update, a `Model: "pro"` subagent (`[PHASE 1 ... READ-ONLY]`) **MUST** investigate in read-only mode and author a Flash-Ready implementation plan draft in `<artifact-dir>/scratch/plan_draft.md`.
   - **Manual Approval Gate (Root UI Publication)**: The Root Mega-Orchestrator publishes `<artifact-dir>/implementation_plan.md` via `write_file` (`Overwrite: true`, `ArtifactMetadata: {RequestFeedback: true, UserFacing: true}`) and **MUST PAUSE** to wait for explicit manual approval from the user. Autonomous execution without user approval is strictly forbidden.
   - **Phase 2 — Pre-Approved Deterministic Execution (`Model: "flash"`, Write-Enabled)**: Once the user approves the plan, the Mega-Orchestrator spawns new `Model: "flash"` subagent(s) (`[PHASE 2 ... WRITE-ENABLED]`) with full context. Phase 2 `flash` subagents operate under the user's pre-approved authorization and MUST NOT generate a duplicate plan or pause again for approval (unless a safety circuit-breaker condition is triggered).
   - **Analytical Exemption**: Requests that are purely analytical or informational (e.g. inspecting logs, checking cluster status, answering questions about code, research) and do not modify state are exempt from requiring an implementation plan, but must still be delegated to a `Model: "pro"` subagent (unless the user explicitly requests otherwise).
8. **Règle d'Alignement Continu Code <-> Documentation (Zero Doc-Drift & Bidirectional Subnet Isolation Invariant)**:
   - **Principe d'indivisibilité** : Une modification de code ou d'infrastructure sans mise à jour simultanée de la documentation correspondante est considérée comme **incomplète et rejetée**.
   - **Périmètre Public Core** : Toute modification apportée aux scripts `scripts/*.sh`, aux modules `tofu/ct-*.tf`, ou aux stacks `stacks/monitoring/` **DOIT** s'accompagner de la mise à jour immédiate des guides correspondants dans `docs/*.md` ou `README.md`.
   - **Interdiction de Fuite d'IPs Privées** : Aucun fichier du périmètre `core` ne doit contenir en dur l'adresse `192.168.1.x`. Utiliser exclusivement les variables dynamiques (`NODE1_IP`, `LAN_SUBNET_CIDR`).
   - **Contrôle Automatique Pré-Commit & Pré-Push** : Les hooks `.githooks/pre-commit` et `.githooks/pre-push` exécutent obligatoirement :
     ```bash
     ./scripts/check-subnet-isolation.sh
     ./scripts/check-doc-sync.sh --git-hook
     ./scripts/check-doc-sync.sh --audit
     ```
     Si une dérive est détectée, le commit/push est immédiatement avorté.
