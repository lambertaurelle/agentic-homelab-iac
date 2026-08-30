# Contributing to `agentic-homelab-iac`

Thank you for checking out this project! This repository contains declarative infrastructure-as-code and container stacks for high-availability Proxmox VE homelabs.

While this repository reflects a personal homelab architecture, **community contributions, bug fixes, feature suggestions, and module improvements are warmly welcomed!** Contributing is completely optional, but if you find something that can be enhanced, optimized, or generalized for the broader homelab community, feel free to open a Pull Request or start a discussion.

---

## 💡 Ways to Contribute

1. **Suggest Features or Enhancements**: Have ideas for new container stacks, OpenTofu modules, or Proxmox automation scripts? Open an [Issue](https://github.com/lambertaurelle/agentic-homelab-iac/issues) with the proposal.
2. **Report Bugs & Edge Cases**: Found an issue with a script, HCL syntax, or permission setting? Open an Issue describing the bug and reproduction steps.
3. **Submit a Pull Request (PR)**: Ready to contribute code? Follow the workflow below.

---

## 🛠 Pull Request Workflow

All external contributions are processed via standard GitHub Pull Requests:

1. **Fork the Repository**:
   Click **Fork** on GitHub to create your own copy of the repository.

2. **Clone your Fork & Create a Feature Branch**:
   ```bash
   git clone https://github.com/<your-username>/agentic-homelab-iac.git
   cd agentic-homelab-iac
   git checkout -b feat/my-new-feature
   ```

3. **Make your Changes**:
   - Follow clean HCL structure in `tofu/`.
   - Maintain POSIX/bash hygiene in `scripts/`.
   - Ensure Docker Compose files in `stacks/` include standard health checks, non-root users where possible, and template `.env.example` files.

4. **Run Pre-Flight Quality Checks**:
   Before committing, verify formatting and syntax:
   ```bash
   # Format OpenTofu HCL
   cd tofu && tofu fmt -check -diff && cd ..

   # Check shell scripts
   shellcheck scripts/*.sh

   # Run pre-commit hooks (if installed)
   pre-commit run --all-files
   ```

5. **Commit & Push**:
   ```bash
   git commit -m "feat(module): add vaultwarden declarative container module"
   git push origin feat/my-new-feature
   ```

6. **Open a Pull Request**:
   - Target the `main` branch of `lambertaurelle/agentic-homelab-iac`.
   - Provide a concise description of what the change does and why it's useful.
   - GitHub Actions will run automated linting, schema validation, and secret scanning.

---

## 🛡 Security & Responsible Disclosure

If you discover a security vulnerability, please do **not** open a public issue. Instead, use GitHub's **Private Vulnerability Reporting** feature under the **Security** tab to report the finding privately.

---

## 📜 Code Style & Principles

- **No Secrets**: Never commit live credentials, API keys, or private tokens. All secrets must remain in example templates (`.env.example`, `terraform.tfvars.example`).
- **Declarative & Idempotent**: OpenTofu modules and shell scripts should be safe to run repeatedly without unintended side effects.
- **Minimal Footprint**: Container stacks should strive for low idle CPU/RAM overhead and sensible resource limits.
