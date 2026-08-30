# Homelab Infrastructure as Code

Declarative infrastructure and container stack management for high-availability multi-node Proxmox homelab environments.

## Language

**Workstation**:
A dedicated containerized development environment running on compute infrastructure for interactive software development and headless AI coding daemons.
_Avoid_: Dev VM, dev box, builder

**Management Workspace**:
An unprivileged utility container (\`mgmt-devops\`) running OpenTofu, git, and administrative tooling to manage cluster infrastructure.
_Avoid_: Control node, admin server, bastard host

**Remote Control Daemon**:
The systemd background service executing \`agy --remote-control\` to facilitate remote web and client orchestration of Antigravity AI agents.
_Avoid_: Agent daemon, agy runner, background bot

**Compute Node**:
The secondary Proxmox hypervisor (`node-2`) dedicated to compute-heavy application stacks, media processing, and developer workstations.
_Avoid_: Worker node, slave node, compute host

**Utility Node**:
The primary Proxmox cluster lead hypervisor (`node-1`) hosting core networking, DNS resolvers, ingress tunnels, and management workspaces.
_Avoid_: Master node, lead server, controller

**Deployment Agent**:
A dedicated lightweight runner or service within the cluster executing automated container pull, health verification, and rollback operations without requiring inbound network ports.
_Avoid_: Deploy bot, webhook listener, push worker

**Production Workload Container**:
A dedicated OpenTofu-managed LXC container provisioned on a cluster node to host production container stacks and persistent application volumes.
_Avoid_: Production VM, prod box, target container
