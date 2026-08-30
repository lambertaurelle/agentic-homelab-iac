# AGENTS.md

## Repository Overview

This repository (`homelab-iac`) manages declarative infrastructure-as-code and container stacks for high-availability and single-node Proxmox VE homelab environments.
- **IaC Engine**: OpenTofu (`tofu/`)
- **Container Stacks**: Docker Compose stacks (`stacks/`)
- **Security & Quality**: Pre-commit hooks (`.pre-commit-config.yaml`), Checkov (`.checkov.yaml`), Trivy (`.trivy.yaml`)
- **Documentation**: Architecture and operational guides located in `docs/`

---

## 🤖 Antigravity 2.0 Subagents & Delegation Registry

When operating in Antigravity or Antigravity 2.0, two specialized custom agents are available in `.agents/agents/`. The general/main agent MUST proactively delegate specialized tasks to them using `invoke_subagent`:

### 1. `@proxmox-ops` (Cluster SRE & Operations)
- **Role**: Proxmox VE Cluster SRE & Operations Agent.
- **Definition**: `.agents/agents/proxmox-ops.md`
- **When to Delegate**:
  - Cluster Day-0 onboarding and provisioning (`proxmox-bootstrap`);
  - Health checks, quorum inspection, and storage pool auditing (`proxmox-cluster-health`);
  - OpenTofu state drift detection and alignment (`proxmox-cluster-health`);
  - Troubleshooting failing LXC or Docker containers, inspecting logs (`proxmox-workload-debug`);
  - Daily updates, rolling reboots, and snapshot backup/restores (`proxmox-maintenance`).

### 2. `@workload-architect` (Application & Workload Architect)
- **Role**: Workload & Application Architect Agent.
- **Definition**: `.agents/agents/workload-architect.md`
- **When to Delegate**:
  - Sizing, designing, and onboarding any new application or service (`proxmox-scaffold-app`);
  - Scaffolding Type 1 Custom In-House apps with Watchtower instant push-to-main CD;
  - Scaffolding Type 2 Third-Party Docker Compose stacks (e.g. Immich, Plex, Vaultwarden);
  - Scaffolding Type 3 Native bare-metal Debian services;
  - Configuring GPU passthrough and storage bind mounts.

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
2. **Specialized Delegation**: Delegate cluster operations to `@proxmox-ops` and application scaffolding to `@workload-architect`.
3. **Skill Evolution**: When building new administrative workflows, author a new skill using `skill-creator` backed by idempotent shell scripts in `scripts/`, then validate it with `skill-evaluator`.
4. **Execution**: Implement changes against specific issues, validating via pre-commit, OpenTofu format/validate, and security scans before submission.
