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

Both subagents are fully empowered with write tools and terminal execution permissions (`enable_write_tools: true`, `enable_subagent_tools: true`, `enable_mcp_tools: true`) to construct implementation plans, modify configurations, run validation commands, and return comprehensive reports.

### Subagent Delegation Routing Table

| Subagent | `TypeName` | Primary Capabilities & Skills | Trigger Patterns / User Requests |
| :--- | :--- | :--- | :--- |
| **`@proxmox-ops`** | `proxmox-ops` | - `proxmox-bootstrap`<br>- `proxmox-cluster-health`<br>- `proxmox-workload-debug`<br>- `proxmox-maintenance` | - Day-0 cluster bootstrap & secrets setup<br>- Quorum audit, storage pool checks, DNS verification<br>- OpenTofu drift detection (`tofu plan`)<br>- Container crash loop, systemd journal, Docker log debug<br>- Daily updates, rolling reboots, VZDump backup/restore |
| **`@workload-architect`** | `workload-architect` | - `proxmox-scaffold-app` | - Deploying / scaffolding new applications or LXCs<br>- Authoring `tofu/ct-<app>.tf` and `stacks/<app>/docker-compose.yml`<br>- Sizing compute, RAM, storage, and GPU passthrough<br>- Configuring Watchtower push-to-main continuous deployment |

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
    "Prompt": "Scaffold a new custom application container for 'genealogy-api' on node 'tuxmox' with instant Watchtower CD."
  }
  ```

---

## 📦 Agent Plugins & Skills

Customizations are packaged as standard plugins under `.agents/plugins/`:

### 1. `proxmox-iac` Plugin (`.agents/plugins/proxmox-iac/`)
- **`proxmox-bootstrap`**: Day-0 interactive cluster discovery, secrets generation, baseline OpenTofu apply, and service setup.
- **`proxmox-cluster-health`**: Read-only cluster quorum audit (`pvecm`), storage reachability (`pvesm`), OpenTofu drift detection (`tofu plan`), and DNS validation.
- **`proxmox-workload-debug`**: Targeted LXC/Docker container troubleshooting, systemd/Docker logs, restart loops, and network routing.
- **`proxmox-scaffold-app`**: Interactive and automated workload onboarding and sizing with continuous deployment boilerplate.
- **`proxmox-maintenance`**: Daily updates engine, rolling reboots with peer node checks, and VZDump backup/restore routines.

### 2. `meta-skills` Plugin (`.agents/plugins/meta-skills/`)
- **`skill-creator`**: Author, structure, and test new agent skills compliant with the agentskills.io spec.
- **`skill-evaluator`**: Audit, score, and lint existing agent skills against best practices.

---

## Engineering Workflow Guidelines

1. **Alignment & Planning**: Before starting complex tasks, use `/grill-me` or `/to-spec` to align on requirements and architecture.
2. **Specialized Delegation**: The main agent must immediately delegate cluster operations to `@proxmox-ops` (`TypeName: "proxmox-ops"`) and application onboarding to `@workload-architect` (`TypeName: "workload-architect"`).
3. **Skill Evolution**: When building new administrative workflows, author a new skill using `skill-creator` backed by idempotent shell scripts in `scripts/`, then validate it with `skill-evaluator`.
4. **Execution**: Implement changes against specific issues, validating via pre-commit, OpenTofu format/validate, and security scans before submission.
