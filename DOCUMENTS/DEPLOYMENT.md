# DEPLOYMENT.md — Colossus-Legal

> **Release workflow:** Workstation Build → DEV (Ansible/Semaphore) → PROD (Ansible/Semaphore)

Last updated: 2026-02-21

---

## ⚠️ Historical Note

This document replaces the original DEPLOYMENT.md (2026-02-03) which described a manual SCP-based deployment workflow using `podman-compose`, `deploy/docker/Dockerfile.*` paths, and image tar transfers. That workflow was superseded by:
- **Ansible-based deployment** via `colossus-ansible` repository (deploy-app role)
- **Container registry** (ghcr.io/rhrywnak) for image distribution
- **Semaphore UI** for one-click deployments

The old document's directory structure (`deploy/docker/`, `deploy/scripts/`, `deploy/env/`) was never implemented. The actual project layout uses component-level Dockerfiles (`backend/Dockerfile`, `frontend/Dockerfile`).

---

## 1. Environment Overview

| Environment | Host | VM | IP | URL |
|-------------|------|----|----|-----|
| **Desktop** | proxima-centauri | — | 10.10.0.99 | `http://localhost:5473` |
| **DEV** | pve-2 | VM-220 | 10.10.100.220 | `https://colossus-legal-dev.cogmai.com` |
| **PROD** | pve-1 | VM-120 | 10.10.100.120 | `https://colossus-legal.cogmai.com` |

### Infrastructure Map

```
Desktop (proxima-centauri)
  ├── Source: ~/Projects/colossus-legal/
  ├── Build: ~/Projects/colossus-ansible/scripts/build-release.sh
  └── Deploy: Ansible playbook or Semaphore UI
          │
          ├── DEV (VM-220, pve-2)
          │   ├── colossus-backend   → port 3403
          │   ├── colossus-frontend  → port 5473
          │   ├── API: https://colossus-legal-api-dev.cogmai.com
          │   └── UI:  https://colossus-legal-dev.cogmai.com
          │
          └── PROD (VM-120, pve-1)
              ├── colossus-backend   → port 3403
              ├── colossus-frontend  → port 5473
              ├── API: https://colossus-legal-api.cogmai.com
              └── UI:  https://colossus-legal.cogmai.com
```

---

## 2. Build Process

### 2.1 Project Layout

```
~/Projects/colossus-legal/
├── backend/
│   ├── Dockerfile          ← Multi-stage: rust:1.84 → debian:bookworm-slim
│   ├── Cargo.toml
│   └── src/
└── frontend/
    ├── Dockerfile          ← Multi-stage: node:20 → nginx:1.27
    ├── package.json
    └── src/
```

Dockerfiles live inside each component directory. Build context is the component directory, not the project root.

### 2.2 Build & Push

```bash
cd ~/Projects/colossus-ansible
./scripts/build-release.sh v0.3.0
```

This script:
1. Validates source directories exist
2. Builds `colossus-backend:v0.3.0` from `backend/Dockerfile`
3. Builds `colossus-frontend:v0.3.0` from `frontend/Dockerfile`
4. Tags both as `latest`
5. Pushes all tags to `ghcr.io/rhrywnak/`

**Prerequisites:**
- Podman installed
- Logged in to ghcr.io: `echo "TOKEN" | podman login ghcr.io -u rhrywnak --password-stdin`
- Source code at `~/Projects/colossus-legal/` (override with `COLOSSUS_LEGAL_SRC` env var)

### 2.3 Container Images

| Image | Registry | Visibility |
|-------|----------|------------|
| `ghcr.io/rhrywnak/colossus-backend` | ghcr.io | Public |
| `ghcr.io/rhrywnak/colossus-frontend` | ghcr.io | Public |

---

## 3. Deployment

### 3.1 Via Ansible (Workstation)

```bash
cd ~/Projects/colossus-ansible

# Deploy to DEV
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal -e version=v0.3.0 \
  -l colossus-dev-app1 --vault-password-file ~/.vault_pass

# Validate DEV, then deploy to PROD
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal -e version=v0.3.0 \
  -l colossus-prod-app1 --vault-password-file ~/.vault_pass
```

The deploy playbook:
1. Pulls images from ghcr.io
2. Writes Quadlet `.container` files, environment files, frontend `config.js`
3. Reloads systemd, restarts containers
4. Runs health checks (backend `/health`, frontend `/`)
5. Writes deployment manifest to `/etc/colossus/deployments/colossus-legal.json`

PROD deployment pauses for interactive confirmation (press Enter to continue).

### 3.2 Via Semaphore UI

1. Build on workstation: `./scripts/build-release.sh v0.3.0`
2. Open https://semaphore.cogmai.com
3. Run "Deploy Colossus-Legal — DEV" → enter version `v0.3.0`
4. Validate DEV via browser
5. Run "Deploy Colossus-Legal — PROD" → enter version `v0.3.0`

Semaphore's Run button is the PROD confirmation gate (no interactive pause).

### 3.3 Rollback

```bash
ansible-playbook playbooks/rollback-app.yml \
  -e app=colossus-legal \
  -l colossus-prod-app1 --vault-password-file ~/.vault_pass
```

Reads the deployment manifest to find the previous version, then redeploys it.

---

## 4. Configuration Management

### 4.1 Secrets (Ansible Vault)

All secrets stored in `~/Projects/colossus-ansible/inventory/group_vars/all/vault.yml`:
- `vault_ghcr_username` / `vault_ghcr_token` — Container registry auth
- `vault_colossus_legal_neo4j_password_dev` — DEV Neo4j password
- `vault_colossus_legal_neo4j_password_prod` — PROD Neo4j password

### 4.2 Environment Configuration

| Variable | DEV (`dev.yml`) | PROD (`prod.yml`) |
|----------|------------------|--------------------|
| Neo4j URI | `bolt://10.10.100.200:7687` | `bolt://10.10.100.110:7687` |
| API URL | `https://colossus-legal-api-dev.cogmai.com` | `https://colossus-legal-api.cogmai.com` |
| CORS Origins | `https://colossus-legal-dev.cogmai.com` | `https://colossus-legal.cogmai.com` |
| Rust log level | `debug` | `warn` |

### 4.3 Traffic Routing

```
Browser → Pi-hole DNS → Traefik (HTTPS:443) → VM-120/VM-220 (HTTP:3403/5473)
Phone   → Cloudflare Edge → Tunnel → Traefik → VM-120 (PROD only)
```

---

## 5. Validation

### 5.1 Automated (Ansible)

```bash
ansible-playbook playbooks/validate-app.yml \
  -e app=colossus-legal \
  -l colossus-dev-app1 --vault-password-file ~/.vault_pass
```

### 5.2 Manual Checklist

After each deployment:
- [ ] Frontend loads at correct URL
- [ ] Case title displays correctly
- [ ] Navigation dropdowns work
- [ ] Documents page shows documents
- [ ] Analysis page shows allegations
- [ ] Evidence page loads

### 5.3 Quick Health Checks

```bash
# DEV
curl -s https://colossus-legal-api-dev.cogmai.com/health
curl -s https://colossus-legal-dev.cogmai.com/ | head -3

# PROD
curl -s https://colossus-legal-api.cogmai.com/health
curl -s https://colossus-legal.cogmai.com/ | head -3
```

---

## 6. Database Sync (Neo4j DEV → PROD)

Managed via Semaphore templates (7-phase playbook with safety gates):

1. Open https://semaphore.cogmai.com
2. Run Neo4j sync phases sequentially (each phase is a separate template)
3. Each phase validates before proceeding

For manual sync procedure, see `NEO4J_DEV_TO_PROD_SYNC_RUNBOOK.md`.

---

## 7. Troubleshooting

```bash
# Container status (needs sudo on CoreOS)
ssh core@10.10.100.220 'sudo podman ps -a'

# Backend logs
ssh core@10.10.100.220 'sudo podman logs colossus-backend 2>&1 | tail -20'

# Frontend logs
ssh core@10.10.100.220 'sudo podman logs colossus-frontend 2>&1 | tail -20'

# Check deployed version
ssh core@10.10.100.220 'cat /etc/colossus/deployments/colossus-legal.json'

# Restart containers
ssh core@10.10.100.220 'sudo systemctl restart colossus-backend colossus-frontend'
```

Common issues:
- **"Failed to fetch" in browser** — Check that `config.js` uses Traefik hostname (not direct IP)
- **Backend won't start** — Check Neo4j connectivity and password in env file
- **Port conflict** — Old orphan containers; `sudo podman stop/rm` the old name
- **Health check fails** — Backend may need 10-15 seconds to connect to Neo4j

---

## 8. Version History

| Date | Version | Changes |
|------|---------|---------|
| 2026-02-03 | 1.0 | Initial document (manual SCP workflow) |
| 2026-02-21 | 2.0 | Complete rewrite: Ansible/Semaphore pipeline, Traefik URLs, vault secrets |
