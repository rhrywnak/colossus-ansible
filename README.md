# Colossus Ansible — Infrastructure & Application Deployment

**Purpose:** Ansible-based automation for the Colossus homelab.
Handles VM provisioning, application deployment, validation, and rollback.

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
cp inventory/group_vars/vault.yml.example inventory/group_vars/vault.yml
ansible-vault encrypt inventory/group_vars/vault.yml
# Edit with: ansible-vault edit inventory/group_vars/vault.yml
```

4. **Verify connectivity:**

```bash
ansible all -m ping --ask-vault-pass
```

---

## Repository Structure

```
colossus-ansible/
├── ansible.cfg                          # Ansible configuration
├── requirements.yml                     # Galaxy collection dependencies
├── inventory/
│   ├── hosts.yml                        # All machines (Proxmox hosts + VMs)
│   └── group_vars/
│       ├── all.yml                      # Shared config (registry, paths)
│       ├── dev.yml                      # DEV environment variables
│       ├── prod.yml                     # PROD environment variables
│       └── vault.yml                    # Encrypted secrets (Ansible Vault)
├── roles/
│   ├── deploy-app/                      # Generic app deployment role (reusable)
│   │   ├── defaults/main.yml
│   │   ├── tasks/
│   │   │   ├── main.yml                 # Entry point (routes to deploy or rollback)
│   │   │   ├── deploy.yml               # Pull images, write configs, restart
│   │   │   ├── rollback.yml             # Read manifest, deploy previous version
│   │   │   └── validate.yml             # Health checks
│   │   └── templates/
│   │       └── deployment-manifest.json.j2
│   └── colossus-legal/                  # App-specific role
│       ├── defaults/main.yml            # Default variables
│       ├── tasks/main.yml               # Write Quadlet + env + config files
│       └── templates/
│           ├── colossus-backend.container.j2
│           ├── colossus-frontend.container.j2
│           ├── colossus-legal-backend.env.j2
│           ├── config.js.j2             # Runtime config injection
│           └── nginx.conf.j2
├── playbooks/
│   ├── deploy-app.yml                   # Deploy any app (version + target)
│   ├── rollback-app.yml                 # Rollback to previous version
│   └── validate-app.yml                 # Run health checks only
├── scripts/
│   └── build-release.sh                 # Build & push container images
└── .gitignore
```

---

## Common Operations

### Deploy Colossus-Legal to DEV

```bash
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal \
  -e version=v1.0.0 \
  -l dev \
  --ask-vault-pass
```

### Deploy to PROD (after DEV validation)

```bash
ansible-playbook playbooks/deploy-app.yml \
  -e app=colossus-legal \
  -e version=v1.0.0 \
  -l prod \
  --ask-vault-pass
```

### Validate (health checks only)

```bash
ansible-playbook playbooks/validate-app.yml \
  -e app=colossus-legal \
  -l dev \
  --ask-vault-pass
```

### Rollback to previous version

```bash
ansible-playbook playbooks/rollback-app.yml \
  -e app=colossus-legal \
  -l prod \
  --ask-vault-pass
```

### Build a release (on workstation)

```bash
./scripts/build-release.sh v1.0.0
```

---

## Adding a New Application

1. Create `roles/<app-name>/` with tasks and templates (copy colossus-legal as starting point)
2. Add app-specific variables to `inventory/group_vars/dev.yml` and `prod.yml`
3. Add any secrets to the vault file
4. Deploy with: `ansible-playbook playbooks/deploy-app.yml -e app=<app-name> -e version=v0.1.0 -l dev`

The `deploy-app` role handles image pulling, service restarts, health checks,
and manifest writing generically. Your app role just defines *what* to deploy.

---

## Secrets Management

Secrets are stored in `inventory/group_vars/vault.yml`, encrypted with Ansible Vault.

```bash
# View current secrets
ansible-vault view inventory/group_vars/vault.yml

# Edit secrets
ansible-vault edit inventory/group_vars/vault.yml

# Change vault password
ansible-vault rekey inventory/group_vars/vault.yml
```

**Never commit unencrypted secrets.** The `.gitignore` excludes common
accident files, but the vault file itself is safe to commit (it's encrypted).

---

## Version Tracking

Each deployment writes a manifest to the target VM:

```
/etc/colossus/deployments/<app-name>.json
```

This records: version, timestamp, previous version, and image tags.
The rollback playbook reads this to determine what to roll back to.

You can check what's deployed anywhere:

```bash
ssh core@<vm-ip> 'cat /etc/colossus/deployments/colossus-legal.json'
```
