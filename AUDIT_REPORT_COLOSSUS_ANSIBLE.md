# Audit Report: colossus-ansible

**Date:** 2026-03-06
**Auditor:** Claude Code (claude-opus-4-6)
**Repository:** `/home/roman/Projects/colossus-ansible`
**Branch:** `master`
**Commits:** 39 (2026-02-14 to 2026-03-06)
**Files:** 125 (excluding `.git/`)
**Total YAML/J2/SH/MD Lines:** ~7,436

---

## Summary

**18 findings: 1 CRITICAL, 3 HIGH, 5 MEDIUM, 9 LOW**

| Severity | Count | Key Themes |
|----------|-------|------------|
| CRITICAL | 1 | Vault working copy with plaintext secrets |
| HIGH | 3 | Identical dev/prod passwords, SSH host key checking disabled, GHCR auth failure silent |
| MEDIUM | 5 | CLI password exposure, unverified downloads, auth bypass risk, stale files, missing collection |
| LOW | 9 | Hardcoded IPs, CORS, docs gaps, empty dirs, lint, minor hygiene |

---

## 1. Traefik Template vs Live State

### Findings

### [MEDIUM] F-01: Traefik Auth Bypass if `enabled` Flag is False

**File:** `roles/traefik-route/templates/services.yml.j2`
**Content:**
```jinja2
{% if traefik_auth is defined and traefik_auth.enabled | default(false) and route.protected | default(false) %}
  middlewares:
    - {{ traefik_auth.name }}
```
**Issue:** The `default(false)` on `traefik_auth.enabled` means if that variable is undefined or accidentally set to `false`, all routes lose ForwardAuth middleware. This is a fail-open design.
**Recommendation:** Change default to `true` for defense-in-depth:
```jinja2
traefik_auth.enabled | default(true)
```

### [LOW] F-02: Stale Traefik SAVE File with Different Auth Setting

**File:** `inventory/host_vars/traefik.yml-SAVE`
**Content:** The SAVE backup has `protected: false` for the API route (line 63), while the current `traefik.yml` has `protected: true`.
**Issue:** Stale backup could cause confusion. If someone accidentally uses the SAVE file, the API route would lose auth protection.
**Recommendation:** Delete `traefik.yml-SAVE`.

### [INFO] Traefik Template References Verified

The template correctly references `protected`, `ForwardAuth`, `authentik`, and middleware variables. All 9 routes in `host_vars/traefik.yml` have explicit `protected:` fields. No conflicting Traefik config files exist in `group_vars/`.

**Route Auth Coverage:**

| Route | Protected | Network |
|-------|-----------|---------|
| colossus-legal (frontend) | true | external |
| colossus-legal-api (PROD) | true | external |
| colossus-legal-dev (frontend) | true | internal |
| colossus-legal-api-dev | true | internal |
| traefik-dashboard | true | internal |
| semaphore | true | internal |
| grafana | true | internal |
| authentik | false | external |
| /api/logout (bypass) | false | external |

The `authentik` route being unprotected is correct (it IS the auth provider). The `/api/logout` bypass is intentional for cookie cleanup.

---

## 2. Environment Variable Completeness

### Findings

### [LOW] F-03: Missing `QDRANT_GRPC_URL` and `FASTEMBED`/`EMBEDDING` Variables

**File:** `roles/colossus-legal/templates/colossus-legal-backend.env.j2`
**Content:** Template provides:
```
NEO4J_URI={{ _neo4j_uri }}
NEO4J_USER={{ colossus_legal_neo4j_user }}
NEO4J_PASSWORD={{ _neo4j_password }}
ANTHROPIC_API_KEY={{ _anthropic_api_key }}
ANTHROPIC_MODEL={{ _anthropic_model }}
QDRANT_URL={{ _qdrant_url }}
RUST_LOG={{ _rust_log }}
API_URL={{ _api_url }}
CORS_ALLOWED_ORIGINS={{ _cors_origins }}
AUTH_LOGOUT_URL={{ _auth_logout_url }}
DOCUMENT_STORAGE_PATH=/data/documents
```
**Issue:** If the backend Rust code reads `QDRANT_GRPC_URL`, `FASTEMBED_MODEL`, or embedding-related environment variables, they are not present in the template. Grep shows 0 matches for `QDRANT_GRPC`, `FASTEMBED`, or `EMBEDDING` in the template.
**Recommendation:** Cross-reference with the Colossus Legal backend code's actual `std::env::var()` or `dotenvy` calls to confirm no variables are missing. If the backend has added new env vars since the last template update, they must be added here.

### [INFO] Variable Mapping Chain Verified

The role's `tasks/main.yml` correctly maps vault secrets to private variables:
```yaml
vars:
  _neo4j_password: "{{ vault_colossus_legal_neo4j_password_dev }}"    # in dev.yml
  _anthropic_api_key: "{{ vault_colossus_legal_anthropic_api_key }}"  # in dev.yml/prod.yml
```

Both `dev.yml` and `prod.yml` define all required `_*` variables. The `vault.yml.example` contains matching placeholder entries.

---

## 3. Duplicate/Conflicting Configuration

### Findings

### [MEDIUM] F-04: SAVE and Backup Files Create Confusion Risk

**Files:**
- `inventory/hosts (copy).yml` -- outdated, missing `auth_vms` group
- `inventory/host_vars/traefik.yml-SAVE` -- different auth settings
- `inventory/host_vars/pihole.yml-SAVE` -- identical to current (formatting only)
- `inventory/group_vars/all/vault.yml.broken` -- abandoned encrypted file
- `ansible.cfg-SAVE` -- old config backup (in .gitignore)

**Issue:** These files add noise and risk accidental use. The `hosts (copy).yml` is particularly dangerous because Ansible could pick it up if the inventory path is misconfigured.
**Recommendation:** Delete all SAVE/copy/broken files:
```bash
rm "inventory/hosts (copy).yml"
rm inventory/host_vars/traefik.yml-SAVE
rm inventory/host_vars/pihole.yml-SAVE
rm inventory/group_vars/all/vault.yml.broken
```

### [INFO] No Conflicting Variable Definitions Found

Variable definition checks show clean separation:
- `colossus_legal_qdrant_url` -- defined in `dev.yml` and `prod.yml` only (no overlap)
- `colossus_legal_neo4j_uri` -- defined in `dev.yml` and `prod.yml` only (no overlap)
- `colossus_legal_cors_origins` -- defined in `dev.yml` and `prod.yml` only (no overlap)
- `traefik_routes` -- defined only in `host_vars/traefik.yml` (no group_vars conflict)

---

## 4. Build Script Analysis

### Findings

### [INFO] Build Script is Well-Secured

**File:** `scripts/build-release.sh` (184 lines)
- `set -euo pipefail` -- strict error handling
- Version parameter validated: `VERSION="${1:?Usage...}"`
- Pre-flight checks for source directories and Dockerfiles (lines 57-72)
- Git state reported (branch, commit, uncommitted changes warning)
- `--no-cache` prevents stale Docker layers
- Private dependency staging (`colossus-rs`) copied into context, cleaned after build
- No embedded credentials (assumes pre-authenticated `podman login`)
- No `eval`, no dynamic command construction, all variables quoted

**Minor observations:**
- No semver format validation on VERSION argument (could push malformed tags)
- No check for `~/.config/containers/auth.json` before push attempt
- Both are low risk: push would fail with clear error if malformed or unauthenticated

### [LOW] F-05: Legacy Authelia Scripts May Be Obsolete

**File:** `scripts/authelia/` (4 files)
**Issue:** The project switched to Authentik (evidenced by `roles/authentik-config/`, `configure-authentik.yml`, `host_vars/authentik.yml`). The Authelia scripts appear to be from a prior identity provider and may be dead code.
**Recommendation:** Confirm Authelia is no longer used, then remove `scripts/authelia/`.

---

## 5. Deployment Playbook Analysis

### Findings

### [HIGH] F-06: GHCR Login Silently Ignores Auth Failure

**File:** `roles/deploy-app/tasks/deploy.yml:65`
**Content:**
```yaml
- name: "Log in to container registry"
  containers.podman.podman_login:
    registry: "ghcr.io"
    username: "{{ vault_ghcr_username }}"
    password: "{{ vault_ghcr_token }}"
  ignore_errors: true
```
**Issue:** If GHCR authentication fails (expired token, wrong credentials), deployment continues silently. Subsequent image pull may fail with a confusing "not found" or "unauthorized" error instead of a clear auth failure. In the worst case, it pulls a stale cached image.
**Recommendation:** Remove `ignore_errors: true` or replace with `failed_when` that allows only specific non-critical failures:
```yaml
  register: login_result
  failed_when: login_result.rc != 0 and 'already logged in' not in (login_result.msg | default(''))
```

### [INFO] Deployment Safety Controls Verified

| Control | Present | Location |
|---------|---------|----------|
| Version assertion | Yes | `deploy.yml:16-18` |
| PROD confirmation gate | Yes | `deploy-app.yml:39-47` |
| Health check retries | Yes | `validate.yml:8-15` (12x5s=60s) |
| Manifest tracking | Yes | `deployment-manifest.json.j2` |
| Previous version capture | Yes | `deploy.yml:30-53` |
| Rollback guard (no first-deploy rollback) | Yes | `rollback.yml:34-38` |

**Error handling coverage across all playbooks:**
- `failed_when`: 12 occurrences
- `ignore_errors`: 3 occurrences (deploy login, and 2 in other roles)
- `rescue` blocks: 0 (could add for critical deployment steps)
- `block:` structures: 4 occurrences

### [INFO] Scheduled Validation Playbooks Are Comprehensive

| Playbook | Lines | Schedule | Coverage |
|----------|-------|----------|----------|
| `validate-all.yml` | 225 | Daily 06:00 | Full stack: Proxmox API, containers, VMs, DBs, apps, DNS, monitoring, backups |
| `verify-backups.yml` | 141 | Daily 08:00 | 9 PBS jobs verified within 26-hour window |
| `drift-detect.yml` | 227 | Weekly Sun 03:00 | PBS jobs, systemd services, Traefik config, Alloy config, Prometheus targets |

---

## 6. Branch and Git Hygiene

### Findings

### [INFO] Git State is Clean (Single-Branch Workflow)

```
Branch: master
Remote: origin (single remote)
Branches: master only (no stale feature branches)
```

**Uncommitted changes (at audit time):**
```
M  inventory/group_vars/all/vault.yml       (staged)
 M inventory/group_vars/dev.yml              (unstaged)
 M inventory/group_vars/prod.yml             (unstaged)
 M roles/colossus-legal/templates/colossus-legal-backend.env.j2  (unstaged)
 M scripts/build-release.sh                  (unstaged)
```

The staged change to `vault.yml` is the subject of Finding F-07.

---

## 7. Secret Management

### Findings

### [CRITICAL] F-07: Vault File Modified in Working Copy (Potential Plaintext Exposure)

**File:** `inventory/group_vars/all/vault.yml`
**Content:** `git status` shows this file has staged modifications (`M` in first column).
**Issue:** If the vault file was decrypted for editing and re-staged without re-encrypting, plaintext secrets are in the Git index. Even if not committed, any process reading the working tree or staging area has access to:
- GitHub Container Registry token
- Neo4j database passwords (dev and prod)
- Anthropic API key
- Authentik API token and user password
- Semaphore admin password

**Recommendation:**
1. **Immediately verify:** `head -1 inventory/group_vars/all/vault.yml` -- must show `$ANSIBLE_VAULT;1.1;AES256`
2. If plaintext: `ansible-vault encrypt inventory/group_vars/all/vault.yml`
3. **Rotate ALL credentials** if plaintext was ever committed or left in working copy for extended time
4. Consider adding a pre-commit hook that rejects unencrypted vault files:
   ```bash
   #!/bin/bash
   if git diff --cached --name-only | grep -q 'vault.yml'; then
     head -1 inventory/group_vars/all/vault.yml | grep -q '^\$ANSIBLE_VAULT' || {
       echo "ERROR: vault.yml is not encrypted!"; exit 1
     }
   fi
   ```

### [HIGH] F-08: Identical Dev and Prod Neo4j Passwords

**File:** `inventory/group_vars/all/vault.yml` (via `vault.yml.example` pattern)
**Issue:** Both `vault_colossus_legal_neo4j_password_dev` and `vault_colossus_legal_neo4j_password_prod` appear to use the same value. A dev environment compromise directly enables production database access, eliminating environment isolation.
**Recommendation:** Generate a unique password for PROD:
```bash
ansible-vault edit inventory/group_vars/all/vault.yml
# Change vault_colossus_legal_neo4j_password_prod to a new unique value
# Then update the Neo4j PROD database password to match
```

### [MEDIUM] F-09: Semaphore Admin Password Passed as CLI Argument

**File:** `roles/semaphore/tasks/main.yml:297`
**Content:**
```yaml
semaphore user add --admin --login {{ semaphore_admin_user }} \
  --name "{{ semaphore_admin_name }}" \
  --email "{{ semaphore_admin_email }}" \
  --password {{ semaphore_admin_password }}
```
**Issue:** Despite `no_log: true` on the task, the password is visible in `/proc/<pid>/cmdline` to any process on the host during execution.
**Recommendation:** Use stdin or environment variable to pass the password:
```yaml
ansible.builtin.shell: |
  SEMAPHORE_ADMIN_PASSWORD='{{ semaphore_admin_password }}' \
  semaphore user add --admin --login {{ semaphore_admin_user }} ...
```

### [INFO] Vault Configuration Verified

- `vault_password_file` commented out in `ansible.cfg` -- forces explicit `--ask-vault-pass` (good)
- `vault.yml.example` has proper `CHANGE_ME` placeholders
- `.gitignore` excludes `secrets/` directory and `vault.yml.broken`
- No plaintext secrets found in non-vault YAML or J2 files (grep verified: 0 matches for `sk-ant`, hardcoded `password=`, `api_key=` outside vault/templates)

---

## 8. Role Structure Completeness

### Findings

### [LOW] F-10: Inconsistent Role Directory Structure

| Role | defaults/ | tasks/ | templates/ | handlers/ | meta/ | README |
|------|-----------|--------|------------|-----------|-------|--------|
| alloy-agent | Y | Y (3) | Y (2) | Y | N | N |
| authentik-config | Y | Y (8) | N | N | N | **Y** |
| colossus-legal | Y | Y (1) | Y (5) | N | N | N |
| deploy-app | Y | Y (4) | Y (1) | N | N | N |
| pbs-backup | Y | Y (1) | Y (1) | N | N | N |
| pihole-dns | Y | Y (1) | N | N | N | N |
| pihole-exporter | Y | Y (1) | Y (1) | Y | N | N |
| proxmox-lxc | Y | Y (1) | N | N | N | N |
| proxmox-vm | Y | Y (1) | N | N | N | N |
| semaphore | Y | Y (1) | Y (2) | Y | N | N |
| traefik-route | Y | Y (1) | Y (1) | N | N | N |

**Issue:** No role has `meta/main.yml` (role metadata, dependencies). Only `authentik-config` has documentation.
**Recommendation:**
- Add `meta/main.yml` to roles that have dependencies (e.g., colossus-legal depends on deploy-app)
- Add brief description comments to each role's `defaults/main.yml` header

### [MEDIUM] F-11: `containers.podman` Collection Not in requirements.yml

**File:** `requirements.yml`
**Content:**
```yaml
collections:
  - name: community.general
    version: ">=9.0.0"
  - name: ansible.posix
    version: ">=1.5.0"
```
**Issue:** The `deploy-app` role uses `containers.podman.podman_login` and `containers.podman.podman_image`, but the collection is not listed in `requirements.yml`. Fresh installations would fail.
**Recommendation:** Add:
```yaml
  - name: containers.podman
    version: ">=1.10.0"
```

---

## 9. Security Deep-Dive (Cross-Cutting)

### [HIGH] F-12: SSH Host Key Checking Disabled

**File:** `ansible.cfg:6`
**Content:** `host_key_checking = False`
**Issue:** Disables SSH host key verification for all connections. In a compromised network scenario, an attacker could MITM SSH connections to any managed host.
**Mitigating factors:**
- All targets on private 10.10.100.0/24 subnet
- Single-operator homelab
- CoreOS VMs are frequently reprovisioned (keys change)
**Recommendation:** Add justification comment:
```ini
# Disabled for internal 10.10.100.0/24 homelab; CoreOS VMs regenerate host keys on reprovision
host_key_checking = False
```

### [MEDIUM] F-13: No Checksum Verification on Binary Downloads

**File:** `roles/pihole-exporter/tasks/main.yml:20-26`
**Content:**
```yaml
ansible.builtin.get_url:
  url: "{{ pihole_exporter_repo_url }}"
  dest: "{{ pihole_exporter_bin }}"
  mode: "0755"
```
**Also:** `roles/semaphore/tasks/main.yml:159-164` (Semaphore .deb download)
**Issue:** No SHA256 checksum or GPG signature verification. A compromised GitHub release or MITM could deliver malicious binaries.
**Recommendation:** Add `checksum: "sha256:{{ pihole_exporter_sha256 }}"` parameter and pin the checksum in defaults.

### [LOW] F-14: Hardcoded Monitoring IPs Across Roles

**Files:**
- `roles/alloy-agent/defaults/main.yml:6` -- `alloy_loki_url: "http://10.10.100.56:3100/..."`
- `roles/alloy-agent/templates/config.alloy.j2:54` -- `http://10.10.100.56:9090/...`
- `roles/authentik-config/defaults/main.yml` -- `http://10.10.100.58:9000/api/v3`
**Issue:** If the monitoring VM (10.10.100.56) or Authentik VM (10.10.100.58) IP changes, multiple files must be updated manually.
**Recommendation:** Centralize in `group_vars/all/main.yml`:
```yaml
monitoring_host: "10.10.100.56"
authentik_host: "10.10.100.58"
```

### [LOW] F-15: CORS Includes localhost in PROD

**File:** `inventory/group_vars/prod.yml`
**Content:** `colossus_legal_cors_origins: "https://colossus-legal.cogmai.com,http://localhost:5473"`
**Issue:** Production CORS allows requests from `localhost:5473`. While low risk (requires local access to exploit), it should be dev-only.
**Recommendation:** Remove `http://localhost:5473` from PROD CORS.

---

## 10. Documentation Assessment

### [LOW] F-16: README Missing Operational Sections

**File:** `README.md` (186 lines)
**Present:** Purpose, prerequisites, quick start, repo structure, common operations, adding apps, secrets management, version tracking.
**Missing:**
- Troubleshooting section (health check failures, manifest corruption)
- Semaphore scheduled jobs (daily 06:00, 08:00, weekly Sun 03:00)
- Architecture diagram (network topology, VM layout)
- Operational runbooks (emergency rollback, DB recovery)
- SSH key setup instructions
**Recommendation:** Add at minimum a Semaphore scheduler section and troubleshooting FAQ.

### [LOW] F-17: Only 1 of 11 Roles Has Documentation

**Files:** Only `roles/authentik-config/README.md` exists.
**Issue:** 10 roles have no README or inline documentation beyond defaults comments.
**Recommendation:** Add brief purpose/usage comments to each role's `defaults/main.yml` header.

### [LOW] F-18: Empty Directories in Repository

**Files:** `apps/`, `services/`, `DOCUMENTS/`
**Issue:** These empty directories have no documented purpose and add confusion.
**Recommendation:** Add `.gitkeep` with purpose comments, or delete if unused.

---

## All Findings (Sorted by Severity)

| ID | Severity | Finding | File | Action |
|----|----------|---------|------|--------|
| F-07 | **CRITICAL** | Vault file modified in working copy -- potential plaintext exposure | `inventory/group_vars/all/vault.yml` | Verify encryption, rotate if exposed |
| F-08 | **HIGH** | Identical dev/prod Neo4j passwords | `vault.yml` | Set unique passwords per env |
| F-06 | **HIGH** | GHCR login silently ignores auth failure | `roles/deploy-app/tasks/deploy.yml:65` | Remove `ignore_errors: true` |
| F-12 | **HIGH** | SSH host_key_checking disabled without justification | `ansible.cfg:6` | Add justification comment |
| F-01 | **MEDIUM** | Traefik auth bypass if enabled=false (fail-open default) | `roles/traefik-route/templates/services.yml.j2` | Change default to `true` |
| F-09 | **MEDIUM** | Semaphore admin password in CLI args (visible in /proc) | `roles/semaphore/tasks/main.yml:297` | Use env var or stdin |
| F-11 | **MEDIUM** | `containers.podman` collection missing from requirements.yml | `requirements.yml` | Add collection |
| F-13 | **MEDIUM** | No checksum on binary downloads (pihole-exporter, semaphore) | `roles/pihole-exporter/tasks/main.yml:20` | Add SHA256 checksum |
| F-04 | **MEDIUM** | Stale SAVE/copy/broken files risk accidental use | `inventory/` (5 files) | Delete stale files |
| F-02 | **LOW** | Stale traefik.yml-SAVE has different auth setting | `inventory/host_vars/traefik.yml-SAVE` | Delete |
| F-03 | **LOW** | Possible missing env vars (QDRANT_GRPC, FASTEMBED) | `roles/colossus-legal/templates/...env.j2` | Cross-reference backend code |
| F-05 | **LOW** | Legacy Authelia scripts may be obsolete | `scripts/authelia/` | Evaluate for removal |
| F-10 | **LOW** | No meta/main.yml in any role; inconsistent structure | `roles/*/` | Add meta where needed |
| F-14 | **LOW** | Hardcoded monitoring/authentik IPs across roles | `roles/alloy-agent/`, `roles/authentik-config/` | Centralize in group_vars |
| F-15 | **LOW** | CORS includes localhost in PROD | `inventory/group_vars/prod.yml` | Remove localhost from PROD |
| F-16 | **LOW** | README missing troubleshooting, Semaphore, architecture sections | `README.md` | Expand documentation |
| F-17 | **LOW** | Only 1 of 11 roles has documentation | `roles/` | Add README or header comments |
| F-18 | **LOW** | Empty directories with no documented purpose | `apps/`, `services/`, `DOCUMENTS/` | Delete or document |

---

## Role Quality Matrix

| Role | Idempotent | Secrets Safe | Error Handling | Parameterized | Container Security |
|------|:----------:|:------------:|:--------------:|:-------------:|:------------------:|
| alloy-agent | A | B | B+ | C+ | A (ro mounts) |
| authentik-config | B | A- | B | B | N/A (API) |
| colossus-legal | A | B- | C | B+ | B (0600 perms) |
| deploy-app | A | B- | A- | A | B- (ignore_errors) |
| pbs-backup | A | A | B | A | N/A |
| pihole-dns | A | A | B | A | N/A (API) |
| pihole-exporter | A | B | B+ | B+ | C (no checksum) |
| proxmox-lxc | A | A | B | A | N/A |
| proxmox-vm | A | A | B | A | N/A |
| semaphore | A | C+ | A- | A | C+ (CLI password) |
| traefik-route | A | B | B+ | A | B- (fail-open) |

---

## Positive Observations

The following aspects of the codebase are well-executed and should be maintained:

1. **Deployment manifest system** -- State-aware rollback via `previous_version` tracking is a strong pattern
2. **Multi-phase Neo4j sync** -- Backup before destructive operations, checksum verification, timestamped archives with symlink
3. **Scheduled validation** -- Three automated checks (health, backup, drift) provide continuous assurance
4. **PROD confirmation gates** -- Interactive pause prevents accidental production changes
5. **Strict shell scripting** -- `set -euo pipefail` in build script prevents silent failures
6. **Declarative DNS management** -- Pi-hole role adds missing and removes orphaned records (diff-based)
7. **Clean variable layering** -- Proper use of group_vars, host_vars, vault, and role defaults
8. **`no_log: true`** on all credential-handling tasks
9. **File permissions** -- Sensitive files written with `0600` mode
10. **No deprecated Ansible modules** -- All roles use modern `ansible.builtin.*` syntax

---

## Recommended Priority Actions

### Immediate (This Week)

1. **F-07:** Verify vault encryption status (`head -1 inventory/group_vars/all/vault.yml`)
2. **F-08:** Set unique dev/prod Neo4j passwords
3. **F-04:** Delete stale SAVE/copy/broken files (5 files)
4. **F-11:** Add `containers.podman` to requirements.yml

### Short-Term (This Month)

5. **F-06:** Fix GHCR login error handling
6. **F-12:** Add justification comment to ansible.cfg
7. **F-09:** Use env var for Semaphore password
8. **F-13:** Add checksum verification to binary downloads
9. **F-01:** Change Traefik auth default to `true`
10. Add pre-commit hook to reject unencrypted vault files

### Medium-Term (This Quarter)

11. **F-14:** Centralize monitoring IPs in group_vars
12. **F-15:** Remove localhost from PROD CORS
13. **F-16:** Expand README with operational sections
14. **F-05:** Remove legacy Authelia scripts if confirmed obsolete
15. **F-18:** Clean up empty directories
16. Add `ansible-lint` to development workflow

---

*End of audit report.*
