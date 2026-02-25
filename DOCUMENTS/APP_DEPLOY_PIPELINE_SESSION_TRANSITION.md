# Application Deploy Pipeline Session Transition — v0.2.0 Release

**Date:** 2026-02-21
**Scope:** Container rebuild, deploy pipeline validation, Semaphore integration
**Duration:** ~6 hours
**Status:** ✅ COMPLETE — v0.2.0 deployed to DEV and PROD, Semaphore templates created
**Previous Transition:** Phase 7A Stages 7–9 (2026-02-20) — Phase 7A complete

---

## 1. What Was Accomplished This Session

### 1.1 colossus-homelab Repository — ✅

Created `rhrywnak/colossus-homelab` GitHub repository and initialized local git tracking for all homelab documentation and scripts in `~/Projects/colossus-homelab/`. Attached repo to Claude Projects for AI-assisted access.

### 1.2 build-release.sh Rewrite — ✅

The original `build-release.sh` (written during Phase 5B design) had never been tested end-to-end. It contained:
- Placeholder registry (`ghcr.io/GITHUB_USERNAME`)
- Wrong Dockerfile paths (`deploy/docker/Dockerfile.backend`) — that directory never existed
- Wrong build context (project root `.` instead of component directories)

**Rewritten** to match the actual `colossus-legal` project layout:
- Dockerfiles at `backend/Dockerfile` and `frontend/Dockerfile`
- Build context is each component directory, not the project root
- Registry hardcoded to `ghcr.io/rhrywnak`
- Validation checks for actual Dockerfile locations before building

### 1.3 GitHub PAT & Ansible Vault Rebuild — ✅

**Problem:** Old GitHub PAT returned 401 ("Bad credentials"). Token had expired or been invalidated despite showing "no expiration" in GitHub UI.

**Resolution:**
1. Deleted old PAT, generated new classic token (scopes: `write:packages`, `read:packages`, `delete:packages`)
2. Verified new token: `curl -H "Authorization: Bearer TOKEN" https://api.github.com/user`
3. Logged into ghcr.io: `echo TOKEN | podman login ghcr.io -u rhrywnak --password-stdin`

**Vault rebuild:** Original vault password no longer decrypted the vault file (cause unknown — possibly encrypted with a different password during initial Phase 5B setup). Recreated vault from `vault.yml.example` with current values.

### 1.4 Ansible Vault Restructure — ✅

Discovered that `inventory/group_vars/vault.yml` wasn't being loaded by Ansible because no group named `vault` exists. The file had been tracked from before the `.gitignore` rule was added, masking the issue during Phase 5B.

**Fix:** Moved to directory-based group_vars:
```
inventory/group_vars/
├── all/
│   ├── main.yml          ← was all.yml
│   ├── vault.yml          ← encrypted secrets
│   └── vault.yml.example
├── dev.yml
├── prod.yml
├── coreos_vms.yml
├── backup.yml
├── infrastructure.yml
└── proxmox.yml
```

Ansible auto-loads all files in a `group_vars/<group>/` directory, so both `main.yml` and `vault.yml` load for every host.

### 1.5 Inventory Environment Groups — ✅

The `deploy-app` playbook and `colossus-legal` role use `'prod' in group_names` and `'dev' in group_names` for environment detection (Neo4j password selection, PROD confirmation pause, deployment manifest). But no `dev` or `prod` groups existed.

**Fix:** Added to `inventory/hosts.yml`:
```yaml
    dev:
      hosts:
        colossus-dev-db1:
        colossus-dev-app1:
    prod:
      hosts:
        colossus-prod-db1:
        colossus-prod-app1:
```

Hosts can belong to multiple groups — this doesn't affect existing group memberships.

### 1.6 deploy-app.yml Fixes — ✅

| Fix | Reason |
|-----|--------|
| Added `become: true` | CoreOS connects as `core` but `/etc/colossus/` requires root |
| Added `ignore_errors: true` on `podman_login` | `containers.podman.podman_login` module fails with ghcr.io 403, but images are public |
| Made PROD pause Semaphore-compatible | Added `confirm_prod` variable — `when: not (confirm_prod | default(false) | bool)` |

### 1.7 API URL & CORS Fix — ✅

Frontend `config.js` was pointing to `http://{{ ansible_host }}:3403` (direct IP over HTTP). When accessed via `https://colossus-legal-dev.cogmai.com`, the browser blocked mixed content (HTTPS page → HTTP API).

**Fix:** Updated `dev.yml` and `prod.yml`:
- DEV API URL: `https://colossus-legal-api-dev.cogmai.com`
- PROD API URL: `https://colossus-legal-api.cogmai.com`
- Added `CORS_ALLOWED_ORIGINS` to backend env template
- DEV CORS: `https://colossus-legal-dev.cogmai.com,http://localhost:5473`
- PROD CORS: `https://colossus-legal.cogmai.com,http://localhost:5473`

### 1.8 Orphan Container Cleanup — ✅

The original v0.1.0 deployment (via Butane/Ignition) used container name `colossus-legal-backend`. The Ansible deployment uses `colossus-backend`. Both containers tried to bind port 3403, causing health check failures.

**Fix:** Manually stopped and removed orphan `colossus-legal-backend` containers on VM-220 and VM-120. Old Quadlet files were already replaced by Ansible.

### 1.9 Semaphore Deploy Templates — ✅

Created two new Semaphore templates for one-click deployments:

| Template | Limit | Environment | Survey |
|----------|-------|-------------|--------|
| Deploy Colossus-Legal — DEV | `colossus-dev-app1` | `colossus-legal-dev` | `version` |
| Deploy Colossus-Legal — PROD | `colossus-prod-app1` | `colossus-legal-prod` (`confirm_prod: true`) | `version` |

DEV template tested end-to-end via Semaphore UI — successful.

### 1.10 Documentation Overhaul — ✅

Created/updated six documents to capture lessons learned and correct stale documentation:

1. **APP_DEPLOY_PIPELINE_SESSION_TRANSITION.md** — This document (project knowledge)
2. **ANSIBLE-README.md** — Rewritten with correct commands, vault paths, Semaphore workflow
3. **DEPLOYMENT.md** — Complete v2.0 rewrite replacing obsolete SCP-based workflow
4. **CONTAINERIZATION_GUIDE_ADDENDUM.md** — Adds build-release.sh as standard build workflow
5. **MASTER_CONTEXT_v6_to_v7_DELTA.md** — 10 targeted changes to produce Master Context v7
6. **COLOSSUS_MASTER_TASK_TRACKER.md** — Consolidated living tracker replacing stale COLOSSUS_HL_TASK_TRACKER.md

---

## 2. Files Created/Modified

### 2.1 colossus-ansible Changes

| File | Change |
|------|--------|
| `scripts/build-release.sh` | Complete rewrite — correct paths, registry, build context |
| `playbooks/deploy-app.yml` | Added `become: true`, Semaphore-compatible PROD pause |
| `roles/deploy-app/tasks/deploy.yml` | `ignore_errors: true` on `podman_login` |
| `inventory/hosts.yml` | Added `dev` and `prod` groups |
| `inventory/group_vars/all/main.yml` | Moved from `all.yml` |
| `inventory/group_vars/all/vault.yml` | Recreated with new PAT |
| `inventory/group_vars/all/vault.yml.example` | Moved from root |
| `inventory/group_vars/dev.yml` | API URL → Traefik hostname, added CORS |
| `inventory/group_vars/prod.yml` | API URL → Traefik hostname, added CORS |
| `roles/colossus-legal/templates/colossus-legal-backend.env.j2` | Added `CORS_ALLOWED_ORIGINS` |
| `.gitignore` | Removed `group_vars/` exclusion |

### 2.2 colossus-homelab Changes

| File | Change |
|------|--------|
| `.gitignore` | Created |
| All existing docs/scripts | Initial commit |
| `DEPLOYMENT.md` | v2.0 rewrite — Ansible/Semaphore pipeline replaces SCP workflow |
| `containerization/CONTAINERIZATION_GUIDE_ADDENDUM.md` | New — build-release.sh as standard workflow |
| `COLOSSUS_MASTER_TASK_TRACKER.md` | New — consolidated living tracker (replaces COLOSSUS_HL_TASK_TRACKER.md) |

### 2.3 Project Knowledge (Claude Project)

| File | Change |
|------|--------|
| `APP_DEPLOY_PIPELINE_SESSION_TRANSITION.md` | New — this document |
| `MASTER_CONTEXT_v6_to_v7_DELTA.md` | New — 10 targeted changes for v7 |

---

## 3. Key Decisions Made

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | Rewrite build-release.sh from scratch | Incremental sed patches were causing cascading errors — script had never been tested |
| 2 | Recreate vault rather than recover | Password mismatch with unknown cause; faster to rebuild with known values |
| 3 | Move vault.yml into all/ directory | Ansible only auto-loads group_vars files matching a group name; directory-based loading is more robust |
| 4 | Add dev/prod groups (hosts in multiple groups) | Environment detection via `group_names` is idiomatic Ansible; cleaner than host_vars |
| 5 | `ignore_errors` on podman_login | Images are public; podman_login module has ghcr.io compatibility issues; not worth blocking deploys |
| 6 | `confirm_prod` variable for Semaphore | `ansible.builtin.pause` hangs in non-interactive environments; Semaphore's Run button is the gate |
| 7 | API URLs via Traefik hostnames | Mixed content (HTTPS page → HTTP API) is blocked by browsers; all traffic must route through Traefik |

---

## 4. Lessons Learned

| # | Lesson |
|---|--------|
| 1 | **Never trust untested automation scripts** — `build-release.sh` was written during design with assumed paths. Always dry-run new scripts before committing. |
| 2 | **Ansible group_vars files must match group names** — a file named `vault.yml` only loads if there's a group called `vault`. Use directory-based layout (`all/vault.yml`) for global secrets. |
| 3 | **`.gitignore` rules block new files in tracked directories** — the `group_vars/` exclusion was added after initial files were tracked, so deletions committed but new additions were silently ignored. |
| 4 | **GitHub PATs can silently die** — even tokens showing "no expiration" and "last used within 2 weeks" can return 401. Always test with `curl https://api.github.com/user` before debugging complex issues. |
| 5 | **Container name changes cause port conflicts** — renaming from `colossus-legal-backend` to `colossus-backend` left orphan containers binding the same port. Stop old containers before deploying new names. |
| 6 | **CoreOS VMs need `become: true` for Ansible** — connecting as `core` user but writing to `/etc/` requires root escalation. CoreOS has passwordless sudo for `core`. |
| 7 | **`ANSIBLE_VAULT_PASSWORD_FILE` env var conflicts with `--vault-password-file` flag** — Ansible sees two vault IDs and errors with "specify --encrypt-vault-id". Use one or the other, not both. |
| 8 | **Frontend API URLs must use Traefik hostnames in containerized deployments** — direct IP+port works for LAN testing but fails through Traefik/Cloudflare due to mixed content blocking. |
| 9 | **Semaphore CLI args field is for Ansible flags, not playbook arguments** — `--limit` goes in the dedicated Limit field, not CLI args (Semaphore passes CLI args as positional arguments). |
| 10 | **Document while details are fresh** — this session's friction points would have been avoided with proper end-to-end testing documentation from Phase 5B. The gap between design and execution was ~12 days. |

---

## 5. Git Commits This Session

### colossus-homelab
| # | Message |
|---|---------|
| 1 | Initial commit: Colossus homelab documentation and scripts |
| 2 | docs: Rewrite DEPLOYMENT.md v2.0, add containerization addendum, add master task tracker |

### colossus-ansible
| # | Message |
|---|---------|
| 1 | Deploy v0.2.0: fix build pipeline, add env groups, vault restructure |
| 2 | Add missing group_vars/all/ directory, fix .gitignore, Semaphore-compatible PROD pause |
| 3 | Fix API URLs and CORS for Traefik routing, add Semaphore deploy templates |
| 4 | docs: Rewrite ANSIBLE-README.md with correct commands and Semaphore workflow |

---

## 6. Current Deployment State

### 6.1 Container Images

| Image | Tag | Status |
|-------|-----|--------|
| `ghcr.io/rhrywnak/colossus-backend` | v0.2.0, latest | ✅ Pushed |
| `ghcr.io/rhrywnak/colossus-frontend` | v0.2.0, latest | ✅ Pushed |

### 6.2 Running Deployments

| Host | Environment | Version | Health |
|------|-------------|---------|--------|
| VM-220 (colossus-dev-app1) | DEV | v0.2.0 | ✅ Backend OK, Frontend OK |
| VM-120 (colossus-prod-app1) | PROD | v0.2.0 | ✅ Backend OK, Frontend OK |

### 6.3 Semaphore Templates (16 total)

Previous 14 templates plus:

| Template | Playbook | Status |
|----------|----------|--------|
| Deploy Colossus-Legal — DEV | `playbooks/deploy-app.yml` | ✅ Tested via Semaphore |
| Deploy Colossus-Legal — PROD | `playbooks/deploy-app.yml` | ✅ Created |

---

## 7. Known Issues / Remaining Cleanup

| # | Issue | Priority | Notes |
|---|-------|----------|-------|
| 1 | Old Butane/Ignition configs reference `colossus-legal-backend` container name | Medium | Orphan containers may respawn after VM reboot if old Ignition persists |
| 2 | `containers.podman.podman_login` fails with ghcr.io | Low | Images are public; `ignore_errors` is a fine workaround |
| 3 | "Junk after JSON data" Ansible warnings on CoreOS | Low | Cosmetic — caused by OSC 8 terminal escape sequences |
| 4 | Semaphore PROD deploy template not yet tested | Medium | Created but not run — DEV was validated |
| 5 | `rollback-app.yml` needs same `become: true` and `confirm_prod` fixes | Medium | Will fail without these if run |

---

## 8. Build & Deploy Workflow (Validated)

### From Workstation

```bash
# 1. Build and push
cd ~/Projects/colossus-ansible
./scripts/build-release.sh v0.3.0

# 2. Deploy to DEV
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal -e version=v0.3.0 \
  -l colossus-dev-app1 --vault-password-file ~/.vault_pass

# 3. Validate DEV, then deploy to PROD
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal -e version=v0.3.0 \
  -l colossus-prod-app1 --vault-password-file ~/.vault_pass
```

### From Semaphore

1. Build on workstation: `./scripts/build-release.sh v0.3.0`
2. Semaphore → Run "Deploy Colossus-Legal — DEV" → enter version `v0.3.0`
3. Validate DEV
4. Semaphore → Run "Deploy Colossus-Legal — PROD" → enter version `v0.3.0`

---

## 9. Next Session Priorities

See `COLOSSUS_MASTER_TASK_TRACKER.md` for the full living tracker. Recommended order:

| Priority | Task | ID |
|----------|------|----|
| 1 | Apply Master Context v6→v7 delta | HIGH-03 |
| 2 | Commit all documentation updates to both repos | HIGH-04 |
| 3 | Fix rollback-app.yml (become, confirm_prod) | HIGH-02 |
| 4 | Test Semaphore PROD deploy template with next release | HIGH-01 |
| 5 | Design automated version tagging system | MED-04 |
| 6 | Design and deploy build VM on pve-2 | MED-05 |
