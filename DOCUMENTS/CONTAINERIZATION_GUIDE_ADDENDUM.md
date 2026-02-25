# Containerization Guide — Addendum (2026-02-21)

**Applies to:** `colossus-homelab/containerization/CONTAINERIZATION_GUIDE.md`

---

## Standard Build Workflow

The manual build steps in the original CONTAINERIZATION_GUIDE.md (Steps 2–4) have been automated by `build-release.sh` in the `colossus-ansible` repository. **This is now the standard workflow for all releases.**

### Automated Build & Push

```bash
cd ~/Projects/colossus-ansible
./scripts/build-release.sh v0.3.0
```

This replaces the manual sequence of:
```bash
cd backend && podman build ...
cd frontend && podman build ...
podman tag ... && podman push ...
```

### What build-release.sh Does

1. Validates source directories exist at `~/Projects/colossus-legal/` (override with `COLOSSUS_LEGAL_SRC`)
2. Builds backend from `backend/Dockerfile` with `backend/` as build context
3. Builds frontend from `frontend/Dockerfile` with `frontend/` as build context
4. Tags both images with version and `latest`
5. Pushes all tags to `ghcr.io/rhrywnak/`

### Critical: Build Context

Dockerfiles are designed to run with their **component directory** as build context — not the project root. The `COPY` instructions reference files relative to the component:

```
# Backend Dockerfile: COPY Cargo.toml Cargo.lock ./
# Build context must be: ~/Projects/colossus-legal/backend/

# Frontend Dockerfile: COPY package.json package-lock.json ./
# Build context must be: ~/Projects/colossus-legal/frontend/
```

The original CONTAINERIZATION_GUIDE.md correctly states "build from within each component directory." The `build-release.sh` script automates this.

### What the Original Guide Still Covers

The CONTAINERIZATION_GUIDE.md remains the authoritative reference for:
- **Step 1:** React runtime config pattern (one-time code change, already done)
- **Dockerfile explanations:** Multi-stage build, dependency caching, Rust learning notes
- **Troubleshooting:** Build failures, container debugging, push authentication
- **Architecture rationale:** Why debian-slim over Alpine, why multi-stage, etc.

### What Has Changed Since the Original Guide

| Topic | Original Guide (v1.0) | Current State |
|-------|----------------------|---------------|
| Build commands | Manual `podman build` per component | `build-release.sh` automates both |
| Push to ghcr.io | Manual `podman tag` + `podman push` | Included in `build-release.sh` |
| Deployment | "Deploy via Ansible: deploy-app.yml" | Fully validated — Ansible + Semaphore |
| Image visibility | "Private by default" | Changed to **public** during Phase 4A |
| API URL injection | `COLOSSUS_API_URL` env var → `docker-entrypoint.sh` | `config.js` written by Ansible template |
| Frontend nginx.conf | Bundled with image | Ansible template overwrites at deploy time |
| Image tags | v0.1.0 | v0.2.0 (current) |

### Prerequisites for Building

```bash
# One-time: login to ghcr.io
echo "YOUR_GITHUB_PAT" | podman login ghcr.io -u rhrywnak --password-stdin

# PAT scopes needed: write:packages, read:packages, delete:packages
# Generate at: https://github.com/settings/tokens
```

If the PAT expires or is revoked, `build-release.sh` will fail at the push step. The build itself doesn't require authentication.

### Full Release Workflow

```bash
# 1. Build and push images
cd ~/Projects/colossus-ansible
./scripts/build-release.sh v0.3.0

# 2. Deploy to DEV (via workstation or Semaphore)
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal -e version=v0.3.0 \
  -l colossus-dev-app1 --vault-password-file ~/.vault_pass

# 3. Validate DEV
curl -s https://colossus-legal-api-dev.cogmai.com/health
# Browser: https://colossus-legal-dev.cogmai.com

# 4. Deploy to PROD
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal -e version=v0.3.0 \
  -l colossus-prod-app1 --vault-password-file ~/.vault_pass
```

Or via Semaphore UI — see `DEPLOYMENT.md` for details.
