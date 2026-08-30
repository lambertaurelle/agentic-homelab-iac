# Domain Docs

How engineering skills and autonomous agents should consume this repository's domain documentation and ubiquitous language.

## Authoritative Sources

Before exploring or planning changes, read:

- **[`CONTEXT.md`](file:///root/homelab-iac/CONTEXT.md)** at the repository root: the single source of truth for ubiquitous homelab domain vocabulary and prohibited synonyms.
- **`docs/adr/`**: Architectural Decision Records (ADRs) that touch the area you are working in (e.g., container privileges, storage architecture, network routing).

If `docs/adr/` does not exist or has no relevant files, **proceed silently**. Do not flag its absence or create empty stubs upfront. The `/domain-modeling` skill creates ADRs lazily when architectural decisions are finalized.

## Repository Layout

This repository follows a **single-context layout** for homelab infrastructure:

```text
/
├── CONTEXT.md                   ← Canonical domain vocabulary and avoided synonyms
├── AGENTS.md                    ← Agent entrypoint and repository guidelines
├── docs/
│   ├── ARCHITECTURE.md          ← Infrastructure architecture and topology
│   ├── adr/                     ← Architectural Decision Records (e.g. 0001-unprivileged-lxc.md)
│   └── agents/                  ← Operational agent specs (domain.md, issue-tracker.md, triage-labels.md)
├── tofu/                        ← OpenTofu / Terraform infrastructure definitions
├── stacks/                      ← Docker Compose application stacks (immich, monitoring, seedbox, etc.)
└── scripts/                     ← Deployment, maintenance, and backup automation scripts
```

## Canonical Domain Vocabulary

All agent outputs—including issue titles, briefs, PR descriptions, commit messages, code comments, and documentation—MUST adhere to the canonical domain terms defined in [`CONTEXT.md`](file:///root/homelab-iac/CONTEXT.md):

| Canonical Term | Definition | Avoided Synonyms |
| :--- | :--- | :--- |
| **`Workstation`** | Dedicated containerized development environment running on compute infrastructure for interactive software development and headless AI coding daemons. | Dev VM, dev box, builder |
| **`Management Workspace`** | Unprivileged utility container (`mgmt-devops`) running OpenTofu, git, and administrative tooling to manage cluster infrastructure. | Control node, admin server, bastard host |
| **`Remote Control Daemon`** | Systemd background service executing `agy --remote-control` to facilitate remote web and client orchestration of Antigravity AI agents. | Agent daemon, agy runner, background bot |
| **`Compute Node`** | Secondary Proxmox hypervisor (`tuxmox`) dedicated to compute-heavy application stacks, media processing, and developer workstations. | Worker node, slave node, compute host |
| **`Utility Node`** | Primary Proxmox cluster lead hypervisor (`proxmox`) hosting core networking, DNS resolvers, ingress tunnels, and management workspaces. | Master node, lead server, controller |

### Vocabulary Rules

1. **Use the canonical terms**: Always use terms as defined in [`CONTEXT.md`](file:///root/homelab-iac/CONTEXT.md). Do not drift to synonyms the glossary explicitly avoids.
2. **Missing concepts**: If a concept is missing from the glossary, do not invent arbitrary synonyms. Note the gap for resolution via `/domain-modeling`.
3. **Challenge terminology**: When interacting with users or inspecting tickets, actively flag ambiguous or deprecated terms.

## Flag ADR Conflicts

If a proposed change or recommendation contradicts an existing ADR in `docs/adr/`, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0001 (unprivileged LXC containers), but worth reopening because…_
