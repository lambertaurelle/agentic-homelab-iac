# AGENTS.md

## Repository Overview

This repository (`homelab-iac`) manages declarative infrastructure-as-code and container stacks for high-availability and single-node Proxmox VE homelab environments.
- **IaC Engine**: OpenTofu (`tofu/`)
- **Container Stacks**: Docker Compose stacks (`stacks/`)
- **Security & Quality**: Pre-commit hooks (`.pre-commit-config.yaml`), Checkov (`.checkov.yaml`), Trivy (`.trivy.yaml`)
- **Documentation**: Architecture and operational guides located in `docs/`

---

## 🤖 Antigravity Subagents & Mandatory Delegation Registry

When operating in Antigravity or Antigravity 2.0, two specialized custom subagents are declared in `.agents/agents/`. The main agent MUST proactively delegate domain-specific tasks to them using `invoke_subagent` rather than attempting to execute them directly in the root session.

Both subagents are fully empowered with write tools and terminal execution permissions (`tools: [run_command, write_to_file, ...]`, `commandExecutionPolicy: auto_execute`, `enable_write_tools: true`) to construct implementation plans, modify configurations, run commands directly in the terminal, and return comprehensive reports.

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
- **Invocation Example**:
  ```json
  {
    "TypeName": "proxmox-ops",
    "Role": "Proxmox Cluster SRE",
    "Prompt": "Run a full health check on the Proxmox cluster, audit quorum, check storage pools, and detect OpenTofu state drift."
  }
  ```

#### 2. `@workload-architect` (Application & Workload Architect)
- **TypeName**: `workload-architect`
- **Definition**: `.agents/agents/workload-architect.md`
- **Capabilities**: Planning, generating OpenTofu container modules, Docker Compose stacks, `.env.example`, and Watchtower deployment snippets.
- **Invocation Example**:
  ```json
  {
    "TypeName": "workload-architect",
    "Role": "Workload Architect",
    "Prompt": "Scaffold a new custom application container for 'custom-api' on node 'node-2' with instant Watchtower CD."
  }
  ```

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
2. **Specialized Delegation**: The main agent must immediately delegate cluster operations to `@proxmox-ops` (`TypeName: "proxmox-ops"`) and application onboarding to `@workload-architect` (`TypeName: "workload-architect"`).
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
