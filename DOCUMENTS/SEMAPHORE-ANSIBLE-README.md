# Colossus-Ansible — Operational Reference

**Repository:** `rhrywnak/colossus-ansible` (private)
**Control Nodes:** proxima-centauri (workstation), CT-315 (Semaphore)
**Last Updated:** 2026-02-21

---

## Quick Start

### Prerequisites

1. **Ansible on your workstation:**

```bash
# Fedora/RHEL
sudo dnf install ansible-core

# Ubuntu/Debian
sudo apt install ansible-core

# pip (any Linux)
pip install ansible-core --user
```

2. **Install required collections:**

```bash
ansible-galaxy collection install -r requirements.yml
```

3. **Create your vault file (secrets):**

```bash
cp inventory/group_vars/all/vault.yml.example inventory/group_vars/all/vault.yml
ansible-vault encrypt inventory/group_vars/all/vault.yml --vault-password-file ~/.vault_pass
ansible-vault edit inventory/group_vars/all/vault.yml --vault-password-file ~/.vault_pass
```

4. **Verify connectivity:**

```bash
ansible all -m ping --vault-password-file ~/.vault_pass
```

**Important:** Do NOT set both `ANSIBLE_VAULT_PASSWORD_FILE` env var and use `--vault-password-file` flag simultaneously — Ansible will error with "specify --encrypt-vault-id".

---

## Repository Structure

```
colossus-ansible/
├── ansible.cfg
├── requirements.yml
├── inventory/
│   ├── hosts.yml                        # All hosts + group definitions
│   └── group_vars/
│       ├── all/
│       │   ├── main.yml                 # Shared config (apps, registry, paths)
│       │   ├── vault.yml                # Encrypted secrets (Ansible Vault)
│       │   └── vault.yml.example
│       ├── dev.yml                      # DEV environment (API URLs, CORS, Neo4j)
│       ├── prod.yml                     # PROD environment
│       ├── coreos_vms.yml               # CoreOS SSH/Python settings
│       ├── backup.yml
│       ├── infrastructure.yml
│       └── proxmox.yml
├── roles/
│   ├── deploy-app/                      # Generic app deployment role
│   ├── colossus-legal/                  # App-specific config (Quadlet, env, config.js)
│   ├── alloy-agent/                     # Grafana Alloy monitoring agent
│   ├── semaphore/                       # Semaphore UI deployment
│   ├── pihole-dns/                      # Pi-hole DNS record management
│   ├── traefik-route/                   # Traefik routing configuration
│   └── pbs-backup/                      # PBS backup job management
├── playbooks/
│   ├── deploy-app.yml                   # Deploy any app (version + target)
│   ├── rollback-app.yml                 # Rollback to previous version
│   ├── validate-app.yml                 # Run health checks only
│   ├── deploy-alloy.yml                 # Deploy Alloy agents
│   ├── deploy-semaphore.yml             # Deploy Semaphore
│   ├── neo4j-sync/                      # Neo4j dev→prod sync (7 phases)
│   ├── neo4j-sync-full.yml              # One-click full sync
│   ├── validate-all.yml                 # Fleet health check (daily 06:00)
│   ├── verify-backups.yml               # PBS backup verification (daily 08:00)
│   └── drift-detect.yml                 # Config drift detection (weekly Sun 03:00)
├── scripts/
│   ├── build-release.sh                 # Build & push container images
│   └── semaphore/                       # CT-315 lifecycle scripts
└── .gitignore
```

---

## Inventory Groups

```
@all
├── @proxmox          (pve-1, pve-2, pve-3)
├── @coreos_vms
│   ├── @db_vms       (colossus-prod-db1, colossus-dev-db1)
│   └── @app_vms      (colossus-prod-app1, colossus-dev-app1)
├── @infrastructure   (pihole, cloudflared, traefik, semaphore)
├── @backup           (pbs)
├── @storage          (truenas)
├── @dev              (colossus-dev-db1, colossus-dev-app1)
└── @prod             (colossus-prod-db1, colossus-prod-app1)
```

**Note:** App/DB hosts belong to multiple groups (e.g., `colossus-dev-app1` is in `app_vms`, `coreos_vms`, and `dev`). The `dev`/`prod` groups are used for environment detection in deploy playbooks.

---

## Common Operations

### Build a Release (on workstation)

```bash
cd ~/Projects/colossus-ansible
./scripts/build-release.sh v0.3.0
```

Builds both `colossus-backend` and `colossus-frontend` images from `~/Projects/colossus-legal`, tags them, and pushes to `ghcr.io/rhrywnak/`.

### Deploy Colossus-Legal to DEV

```bash
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal \
  -e version=v0.3.0 \
  -l colossus-dev-app1 \
  --vault-password-file ~/.vault_pass
```

### Deploy to PROD (after DEV validation)

```bash
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal \
  -e version=v0.3.0 \
  -l colossus-prod-app1 \
  --vault-password-file ~/.vault_pass
```

Interactive PROD confirmation will pause for Enter. To skip (for Semaphore), add `-e confirm_prod=true`.

### Validate (health checks only)

```bash
ansible-playbook playbooks/validate-app.yml \
  -e app=colossus-legal \
  -l colossus-dev-app1 \
  --vault-password-file ~/.vault_pass
```

### Rollback to previous version

```bash
ansible-playbook playbooks/rollback-app.yml \
  -e app=colossus-legal \
  -l colossus-prod-app1 \
  --vault-password-file ~/.vault_pass
```

---

## Semaphore Workflow

For deployments via Semaphore UI (https://semaphore.cogmai.com):

1. **Build on workstation:** `./scripts/build-release.sh v0.3.0`
2. **Deploy DEV:** Semaphore → Run "Deploy Colossus-Legal — DEV" → enter version `v0.3.0`
3. **Validate DEV** via browser at `https://colossus-legal-dev.cogmai.com`
4. **Deploy PROD:** Semaphore → Run "Deploy Colossus-Legal — PROD" → enter version `v0.3.0`

Semaphore's "Run" button serves as the PROD confirmation gate. The `confirm_prod: true` extra variable in the PROD environment skips the interactive pause.

---

## Secrets Management

Secrets are in `inventory/group_vars/all/vault.yml`, encrypted with Ansible Vault.

```bash
# View
ansible-vault view inventory/group_vars/all/vault.yml --vault-password-file ~/.vault_pass

# Edit
ansible-vault edit inventory/group_vars/all/vault.yml --vault-password-file ~/.vault_pass

# Rekey
ansible-vault rekey inventory/group_vars/all/vault.yml --vault-password-file ~/.vault_pass
```

**Vault password file:** `~/.vault_pass` (chmod 600, never committed).

**Do NOT** set `ANSIBLE_VAULT_PASSWORD_FILE` env var and use `--vault-password-file` flag at the same time.

---

## Version Tracking

Each deployment writes a manifest to the target VM:

```
/etc/colossus/deployments/<app-name>.json
```

Records version, timestamp, previous version, and image tags. The rollback playbook reads this to determine what to roll back to.

```bash
ssh core@<vm-ip> 'cat /etc/colossus/deployments/colossus-legal.json'
```

---

## Adding a New Application

1. Create `roles/<app-name>/` with tasks and templates (copy colossus-legal as a starting point)
2. Add the app definition to `inventory/group_vars/all/main.yml` under the `apps:` dictionary
3. Add environment-specific variables to `dev.yml` and `prod.yml`
4. Add any secrets to `inventory/group_vars/all/vault.yml`
5. Deploy: `ansible-playbook playbooks/deploy-app.yml -e app=<name> -e version=v0.1.0 -l colossus-dev-app1`

---

## Known Issues

| Issue | Workaround |
|-------|------------|
| `podman_login` fails with ghcr.io 403 | Images are public; `ignore_errors: true` on login task |
| "Junk after JSON data" warnings on CoreOS | Cosmetic — OSC 8 terminal escapes from CoreOS bash |
| `ansible.cfg` has no `vault_password_file` or `private_key_file` | Removed for Semaphore compatibility; workstation uses `--vault-password-file` flag or env var |
