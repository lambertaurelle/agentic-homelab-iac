# 🚀 Homelab Workload & Application Onboarding Guide

Authoritative specification and guide for onboarding **custom in-house applications** and **third-party container stacks** onto the Proxmox VE homelab cluster.

---

## 🏗 Deployment Architecture & Workload Types

```mermaid
flowchart TD
    subgraph CustomApp ["1. Custom In-House Applications (Instant CD)"]
        Dev["Push to main (App Repo)"] --> GHA["GitHub Actions Buildx"]
        GHA --> GHCR["Push to GHCR (ghcr.io)"]
        GHA -->|POST /v1/update (or 60s poll)| WT["Watchtower Sidecar (Auto-polling & Port 8081)"]
        WT -->|Instant Container Reload (< 10s)| LiveApp["Target LXC (e.g. CT 701 on tuxmox)"]
    end

    subgraph ThirdParty ["2. Third-Party Stacks (Scheduled Updates)"]
        TP_Reg["Upstream Docker Registry"] -->|Daily 05:00 AM Cron| TP_Cron["scripts/update-cluster-stack.sh"]
        TP_Cron --> LiveTP["Target LXC (e.g. Immich, Seedbox, Kuma)"]
    end
```

---

## ⚡ 1. Rapid Workload Scaffolding

You can onboard a new application in 30 seconds using either the **interactive CLI scaffolder** or the **Antigravity AI Agent Skill**:

### Option A: Interactive CLI Scaffolder (`scripts/scaffold-app.sh`)
From the management workspace (`CT 900`) or repository root:

```bash
# Interactive mode (prompts for type, name, node, port)
./scripts/scaffold-app.sh

# Non-interactive CLI command
./scripts/scaffold-app.sh \
    --type custom \
    --name genealogy-api \
    --node tuxmox \
    --repo lambertaurelle/genealogy \
    --port 3000 \
    --memory 2048 \
    --cores 2 \
    --disk 20 \
    --non-interactive
```

### Option B: Antigravity AI Agent Skill (`proxmox-scaffold-app`)
Ask the agent:
> *"Scaffold a new custom application named genealogy-api on tuxmox with instant CD for repo lambertaurelle/genealogy on port 3000."*

---

## 📁 2. Generated Artifacts Reference

When scaffolding an application named `myapp`, the scaffolder automatically produces:

### 1. OpenTofu LXC Definition (`tofu/ct-myapp.tf`)
```hcl
module "ct_myapp" {
  source = "./modules/app-container"

  node_name   = "tuxmox"
  vm_id       = 702
  hostname    = "myapp"
  description = "Managed by OpenTofu | myapp (custom)"

  cores        = 2
  memory       = 2048
  swap         = 512
  disk_size    = 20
  disk_storage = "local-lvm"

  mac_address  = "bc:24:11:00:07:02"
  ipv4_address = "dhcp"

  ssh_public_keys = var.app_ssh_public_keys
}
```

### 2. Docker Compose Stack (`stacks/myapp/docker-compose.yml`)
```yaml
services:
  app:
    image: ghcr.io/lambertaurelle/myapp:${IMAGE_TAG:-latest}
    container_name: myapp
    restart: unless-stopped
    ports:
      - "3000:3000"
    environment:
      - PORT=3000
      - NODE_ENV=production
    labels:
      - "com.centurylinklabs.watchtower.enable=true"

  watchtower:
    image: containrrr/watchtower:latest
    container_name: myapp-watchtower
    restart: unless-stopped
    command: --interval 60 --label-enable --http-api-update --http-api-periodic-polls --http-api-token "${WATCHTOWER_HTTP_API_TOKEN}"
    environment:
      - WATCHTOWER_HTTP_API_TOKEN=${WATCHTOWER_HTTP_API_TOKEN}
      - DOCKER_API_VERSION=1.45
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /root/.docker/config.json:/config.json:ro
    ports:
      - "8081:8080"
```

### 3. GitHub Actions Continuous Deployment Workflow
Place the generated snippet into `.github/workflows/deploy.yml` in your custom application repository:

```yaml
name: "Build & Deploy to Homelab"

on:
  push:
    branches: [ main ]

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/setup-buildx-action@v3
      - uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  trigger-homelab-deployment:
    needs: build-and-push
    runs-on: ubuntu-latest
    steps:
      - name: Trigger Instant Watchtower Reload
        run: |
          curl -f -sS -X POST \
               -H "Authorization: Bearer ${{ secrets.WATCHTOWER_TOKEN }}" \
               "http://${{ secrets.HOMELAB_APP_HOST }}:8080/v1/update"
```

---

## 🛠 3. Provisioning & Deployment Steps

1. **Review and apply OpenTofu plan**:
   ```bash
   cd tofu
   tofu plan -target=module.ct_myapp
   tofu apply -target=module.ct_myapp
   ```
2. **Bootstrap Docker Host**:
   ```bash
   # Run the universal Docker installer inside the newly provisioned LXC
   pct exec <CTID> -- bash -c "$(curl -fsSL https://.../bootstrap-docker-host.sh)"
   ```
3. **Start the Stack**:
   ```bash
   # Copy stack folder and start Compose
   cd /root/homelab-iac/stacks/myapp
   docker compose up -d
   ```
