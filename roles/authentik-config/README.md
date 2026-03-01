# authentik-config Role

Configures Authentik identity provider via its REST API (`/api/v3/`).

## What it manages

| Resource | Action | API Endpoint |
|----------|--------|-------------|
| Brand | Set domain on default brand | `PATCH /core/brands/{id}/` |
| Groups | Create if missing | `POST /core/groups/` |
| Proxy Provider | Create forward-auth provider | `POST /providers/proxy/` |
| Application | Create and link to provider | `POST /core/applications/` |
| Outpost | Bind provider to embedded outpost | `PATCH /outposts/instances/{id}/` |
| Users | Create with group membership + password | `POST /core/users/` |

## Pattern

API-based role, following the `pihole-dns` pattern. Uses `ansible.builtin.uri` for all REST calls. Runs with `connection: local` — API calls execute from the workstation, not via SSH into the CoreOS VM.

## Idempotency

- Resources are checked before creation (GET → exists? → skip)
- Brand domain is patched only if different
- Groups are additive (never deletes authentik built-in groups)
- Passwords are only set on user creation, not on subsequent runs

## Prerequisites

1. VM-316 running with healthy Authentik containers
2. Initial setup wizard completed (akadmin account created)
3. API token created in Authentik and stored in Ansible Vault (`vault_authentik_api_token`)

## Usage

```bash
# Dry-run
ansible-playbook playbooks/configure-authentik.yml --check

# Execute
ansible-playbook playbooks/configure-authentik.yml

# Verbose (see API responses)
ansible-playbook playbooks/configure-authentik.yml -vv
```

## Variables

See `inventory/host_vars/authentik.yml` for full variable definitions.

Key vault variables:
- `vault_authentik_api_token` — API bearer token
- `vault_authentik_roman_password` — Initial password for user `roman`
