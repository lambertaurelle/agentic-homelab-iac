---
name: proxmox-scaffold-app
description: Interactively scaffold and provision new LXC application containers, Docker Compose stacks, and continuous deployment triggers on Proxmox. Use when the user asks to deploy a new application, create an app container, onboard a custom GitHub repository, scaffold a new workload, add a service to the cluster, or configure Watchtower instant deployment.
---

# Proxmox Application Scaffolder

## Overview
This skill guides the sysadmin or agent through onboarding and deploying new applications onto the Proxmox homelab cluster. It handles the complete lifecycle: requirement gathering, node placement advisory, OpenTofu LXC generation, Docker Compose stack templating (with instant continuous deployment for custom apps), resource sizing, and optional GPU passthrough or storage bind mounts.

## When to Use
Use when:
- Deploying or onboarding any new application or service on the Proxmox cluster;
- Creating an LXC container for a custom in-house GitHub project or third-party container stack;
- Scaffolding a new OpenTofu container (`tofu/ct-<app>.tf`) and Docker Compose boilerplate (`stacks/<app>/`);
- Configuring instant "push-to-main" continuous deployment using the Watchtower HTTP API sidecar.

Do **not** use for:
- Initial Day-0 cluster bootstrapping (use `proxmox-bootstrap`);
- Debugging existing broken containers (use `proxmox-workload-debug`);
- Running routine updates or rolling reboots (use `proxmox-maintenance`).

## Core Process

### 1. Requirements Gathering & Workload Classification
Gather any missing parameters through conversation. Ask only for what wasn't already specified in the user request:

1. **Application Name**: Alphanumeric identifier (e.g. `vaultwarden`, `immich`, `paperless`).
2. **Workload Architecture Type**:
   - **Type 1: Custom In-House Application**: Personal projects requiring instant continuous deployment on `git push origin main`. Uses Watchtower HTTP API sidecar (`POST /v1/update`).
   - **Type 2: Third-Party Stack**: Off-the-shelf container images (e.g. Vaultwarden, Mealie, Paperless). Updated via daily 05:00 AM cron (`update-cluster-stack.sh`).
   - **Type 3: Native Service**: Bare-metal Debian `.deb` package or systemd daemon running without Docker.
3. **Repository URL / Image**: GitHub slug (e.g. `myuser/myapp`) or container registry image.
4. **Target Node Placement**: Primary node or secondary compute node.
5. **Resource Sizing**:
   - Default: `2 CPU cores`, `2048 MB RAM`, `20 GB disk`, port `8080`.
   - Compute-heavy (ML/Databases/Transcoding): `4-6 cores`, `4096-8192 MB RAM`, `40-50 GB disk`.
6. **Hardware Passthrough & Storage**: Prompt if Intel QuickSync / GPU device (`/dev/dri`) or host/NAS storage bind mounts are required.

### 2. Execute Workload Scaffolder CLI
Execute `scripts/scaffold-app.sh` from the repository root:
```bash
# Example: Custom in-house application with Instant CD
./scripts/scaffold-app.sh \
    --type custom \
    --name "<app-name>" \
    --node "<target-node>" \
    --repo "<github-repo-slug>" \
    --port "<port>" \
    --non-interactive
```

This automatically:
- Discovers the next free Container ID and deterministic MAC.
- Creates `tofu/ct-<app-name>.tf` linked to the reusable `modules/app-container`.
- Creates `stacks/instance/<app-name>/docker-compose.yml` (or `stacks/<app-name>/`) with the application and Watchtower sidecar.
- Creates `stacks/instance/<app-name>/.env.example` with a securely generated `WATCHTOWER_HTTP_API_TOKEN`.
- Creates `stacks/instance/<app-name>/github-deploy-workflow.yml.snippet` for GitHub Actions.

### 3. OpenTofu Validation & Secrets Registration
1. Register any environment secrets or custom variables into `scripts/instance/bootstrap-instance-secrets.sh` (or `tofu/terraform.tfvars`).
2. Verify that the generated infrastructure is valid:
```bash
cd tofu
tofu fmt "ct-<app-name>.tf"
tofu validate
tofu plan -target="module.ct_<app_identifier>"
```

### 4. Provide Deployment Snippet to User
For **Custom In-House Applications**, present the `.github/workflows/deploy.yml` snippet to the user so they can commit it to their application repository for automated push-to-main deployment.

## Verification
Confirm the scaffolding is complete only when:
- [ ] `tofu/ct-<app-name>.tf` exists and is formatted (`tofu fmt -check`).
- [ ] `stacks/instance/<app-name>/docker-compose.yml` (or `stacks/<app-name>/`) exists with correct container and port bindings.
- [ ] `tofu validate` succeeds with 0 syntax or schema errors.
- [ ] `tofu plan` displays exactly 1 new container to add without modifying existing production workloads.
- [ ] The user is provided with the allocated CTID, IP, MAC address, and next deployment steps.
