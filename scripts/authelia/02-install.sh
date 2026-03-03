#!/bin/bash
# 02-install.sh — Install and configure Authelia on CT-316
# Run from: workstation (proxima-centauri)
#
# Prerequisites: CT-316 running (01-create.sh completed)
#
# This script:
#   1. Installs SSH + deploys key (for subsequent management)
#   2. Downloads Authelia binary from GitHub releases
#   3. Creates authelia system user
#   4. Generates secrets (JWT, session, storage encryption)
#   5. Deploys configuration.yml and users_database.yml to /mnt/config
#   6. Deploys users_database.yml with placeholder password
#   7. Creates systemd unit + sets ownership on ZFS mounts
#   8. Starts and validates the service
#
# Install method: Direct binary from GitHub releases (Balto APT repo is dead).
# Version pinned in AUTHELIA_VERSION below — update for upgrades.
#
set -euo pipefail

source "$(dirname "$0")/config.sh"

# Authelia version — update here for upgrades
AUTHELIA_VERSION="4.39.15"
AUTHELIA_TARBALL="authelia-v${AUTHELIA_VERSION}-linux-amd64.tar.gz"
AUTHELIA_URL="https://github.com/authelia/authelia/releases/download/v${AUTHELIA_VERSION}/${AUTHELIA_TARBALL}"

echo "=== Step 2: Install Authelia ${AUTHELIA_VERSION} on CT-${CTID} ==="

# --- Pre-flight ---
STATUS=$(ssh ${PVE_HOST} "pct status ${CTID}" 2>/dev/null | awk '{print $2}')
if [ "${STATUS}" != "running" ]; then
    echo "  ✗ CT-${CTID} is not running (status: ${STATUS:-not found})"
    echo "    Run 01-create.sh first."
    exit 1
fi
echo "  ✓ CT-${CTID} is running"

# --- Step 1: Install SSH and deploy key ---
echo ""
echo "  [1/8] Installing SSH and deploying key..."

# Remove stale APT sources from any previous attempt before apt-get update
ssh ${PVE_HOST} "pct exec ${CTID} -- bash -c '
    rm -f /etc/apt/sources.list.d/authelia*.list
    apt-get update -qq
    apt-get install -y -qq openssh-server curl > /dev/null 2>&1
    systemctl enable --now ssh
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
'"

# Deploy SSH public key
PUBKEY=$(cat "${SSH_PUBKEY}")
ssh ${PVE_HOST} "pct exec ${CTID} -- bash -c \"echo '${PUBKEY}' > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys\""

# Clear any stale host key and verify SSH connectivity
ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${IP}" 2>/dev/null || true
sleep 2

if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 root@${IP} "hostname" &>/dev/null; then
    echo "  ✓ SSH connectivity verified (root@${IP})"
else
    echo "  ✗ Cannot SSH to root@${IP}"
    exit 1
fi

# --- Step 2: Download Authelia from GitHub ---
echo ""
echo "  [2/8] Downloading Authelia v${AUTHELIA_VERSION} from GitHub..."

# Check if already installed at this version (idempotent)
CURRENT_VERSION=$(ssh root@${IP} "authelia --version 2>/dev/null | grep -oP 'v\K[0-9]+\.[0-9]+\.[0-9]+' || echo 'none'")
if [ "${CURRENT_VERSION}" = "${AUTHELIA_VERSION}" ]; then
    echo "  ✓ Authelia v${AUTHELIA_VERSION} already installed — skipping download"
else
    ssh root@${IP} "bash -s" << DOWNLOAD
        cd /tmp
        echo "    Downloading ${AUTHELIA_TARBALL}..."
        curl -fsSL -o "${AUTHELIA_TARBALL}" "${AUTHELIA_URL}"
        echo "    Extracting..."
        tar xzf "${AUTHELIA_TARBALL}"
        echo "    Installing binary to /usr/bin/authelia..."
        install -Dm755 authelia /usr/bin/authelia
        rm -f /tmp/${AUTHELIA_TARBALL} /tmp/authelia
        echo "    Installed: \$(/usr/bin/authelia --version 2>&1 | head -1)"
DOWNLOAD
    echo "  ✓ Authelia v${AUTHELIA_VERSION} installed"
fi

# --- Step 3: Create authelia system user ---
echo ""
echo "  [3/8] Creating authelia system user..."
ssh root@${IP} "bash -s" << 'CREATE_USER'
    if id authelia &>/dev/null; then
        echo "    User 'authelia' already exists"
    else
        useradd --system --home-dir /var/lib/authelia --create-home \
            --shell /usr/sbin/nologin --user-group authelia
        echo "    Created system user 'authelia'"
    fi
    echo "    UID=$(id -u authelia), GID=$(id -g authelia)"
CREATE_USER
echo "  ✓ authelia user ready"

# --- Step 4: Generate secrets ---
echo ""
echo "  [4/8] Generating secrets..."
ssh root@${IP} "bash -s" << 'SECRETS'
    SECRETS_DIR="/mnt/config/secrets"
    mkdir -p "${SECRETS_DIR}"

    # Only generate if not already present (idempotent — preserves across rebuilds)
    for SECRET_FILE in jwt_secret session_secret storage_encryption_key; do
        if [ ! -f "${SECRETS_DIR}/${SECRET_FILE}" ]; then
            head -c 64 /dev/urandom | base64 -w 0 > "${SECRETS_DIR}/${SECRET_FILE}"
            chmod 600 "${SECRETS_DIR}/${SECRET_FILE}"
            echo "    Generated: ${SECRET_FILE}"
        else
            echo "    Exists (preserved): ${SECRET_FILE}"
        fi
    done

    echo "  Secrets directory:"
    ls -la "${SECRETS_DIR}/"
SECRETS
echo "  ✓ Secrets ready"

# --- Step 5: Deploy configuration.yml ---
echo ""
echo "  [5/8] Deploying configuration.yml..."

CONFIG_STATUS=$(ssh root@${IP} "[ -f /mnt/config/configuration.yml ] && echo EXISTS || echo MISSING")

if [ "${CONFIG_STATUS}" = "MISSING" ]; then
    # Read secrets and inject into config
    ssh root@${IP} "bash -s" << 'DEPLOY_CONFIG'
        JWT_SECRET=$(cat /mnt/config/secrets/jwt_secret)
        SESSION_SECRET=$(cat /mnt/config/secrets/session_secret)
        STORAGE_KEY=$(cat /mnt/config/secrets/storage_encryption_key)

        cat > /mnt/config/configuration.yml << CONFIGEOF
---
theme: dark
default_2fa_method: totp

server:
  address: 'tcp://0.0.0.0:9091/'

log:
  level: info
  file_path: /mnt/data/authelia.log

totp:
  issuer: cogmai.com
  period: 30
  skew: 1

identity_validation:
  reset_password:
    jwt_secret: '${JWT_SECRET}'

authentication_backend:
  file:
    path: /mnt/config/users_database.yml
    password:
      algorithm: argon2id
      iterations: 3
      memory: 65536
      parallelism: 4
      key_length: 32
      salt_length: 16

session:
  secret: '${SESSION_SECRET}'
  cookies:
    - domain: 'cogmai.com'
      authelia_url: 'https://auth.cogmai.com'
      default_redirection_url: 'https://colossus-legal.cogmai.com'
      expiration: 12h
      inactivity: 1h
      remember_me: 1M

storage:
  encryption_key: '${STORAGE_KEY}'
  local:
    path: /mnt/data/db.sqlite3

notifier:
  filesystem:
    filename: /mnt/data/notification.txt

access_control:
  default_policy: deny

  rules:
    # Authelia portal itself — must be bypass
    - domain: 'auth.cogmai.com'
      policy: bypass

    # Colossus-Legal health/status endpoints — no auth (for monitoring)
    - domain:
        - 'colossus-legal-api.cogmai.com'
        - 'colossus-legal-api-dev.cogmai.com'
      resources:
        - '^/health\$'
        - '^/api/status\$'
      policy: bypass

    # Admin-only services
    - domain:
        - 'semaphore.cogmai.com'
        - 'grafana.cogmai.com'
        - 'traefik.cogmai.com'
      subject:
        - 'group:admin'
      policy: one_factor

    # Colossus-Legal — all authenticated users
    - domain:
        - 'colossus-legal.cogmai.com'
        - 'colossus-legal-api.cogmai.com'
      subject:
        - 'group:admin'
        - 'group:legal_editor'
        - 'group:legal_viewer'
      policy: one_factor

    # DEV environment — admin only
    - domain:
        - 'colossus-legal-dev.cogmai.com'
        - 'colossus-legal-api-dev.cogmai.com'
      subject:
        - 'group:admin'
      policy: one_factor

    # Future: colossus-ai
    - domain:
        - 'colossus-ai.cogmai.com'
        - 'colossus-ai-api.cogmai.com'
      subject:
        - 'group:admin'
        - 'group:ai_user'
      policy: one_factor
CONFIGEOF
        echo "    configuration.yml deployed with inline secrets"
DEPLOY_CONFIG
    echo "  ✓ configuration.yml deployed (fresh)"
else
    echo "  ✓ configuration.yml exists (preserved from previous install)"
fi

# --- Step 6: Deploy users_database.yml ---
echo ""
echo "  [6/8] Deploying users_database.yml..."

USERS_STATUS=$(ssh root@${IP} "[ -f /mnt/config/users_database.yml ] && echo EXISTS || echo MISSING")

if [ "${USERS_STATUS}" = "MISSING" ]; then
    cat << 'USERS_EOF' | ssh root@${IP} "cat > /mnt/config/users_database.yml"
---
users:
  roman:
    disabled: false
    displayname: "Roman"
    email: roman@cogmai.com
    groups:
      - admin
      - legal_editor
      - ai_user
    password: "$argon2id$PLACEHOLDER_HASH_REPLACE_ME"
USERS_EOF
    echo "  ⚠ users_database.yml deployed with PLACEHOLDER password hash"
    echo "    You MUST generate a real hash before testing login:"
    echo "    ssh root@${IP} \"authelia crypto hash generate argon2\""
    echo "    Then update /mnt/config/users_database.yml with the output."
else
    echo "  ✓ users_database.yml exists (preserved from previous install)"
fi

# --- Step 7: Configure systemd + set ownership ---
echo ""
echo "  [7/8] Configuring systemd and file ownership..."
ssh root@${IP} "bash -s" << 'SYSTEMD'
    # Set ownership on externalized mounts for authelia user
    AUTHELIA_UID=$(id -u authelia)
    AUTHELIA_GID=$(id -g authelia)
    echo "    Authelia user: UID=${AUTHELIA_UID}, GID=${AUTHELIA_GID}"

    chown -R ${AUTHELIA_UID}:${AUTHELIA_GID} /mnt/data
    chown -R ${AUTHELIA_UID}:${AUTHELIA_GID} /mnt/config
    chmod 600 /mnt/config/secrets/*
    echo "    ✓ Ownership set on /mnt/data and /mnt/config"

    # Create systemd unit
    cat > /etc/systemd/system/authelia.service << 'UNIT'
[Unit]
Description=Authelia Authentication Server
After=network.target

[Service]
Type=simple
User=authelia
Group=authelia
ExecStart=/usr/bin/authelia --config /mnt/config/configuration.yml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

# Hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/mnt/data
ReadOnlyPaths=/mnt/config
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    echo "    ✓ systemd unit created"
SYSTEMD

# --- Step 8: Start and validate ---
echo ""
echo "  [8/8] Starting Authelia..."
ssh root@${IP} "systemctl enable authelia && systemctl restart authelia"
sleep 3

# Check service status
SVC_STATUS=$(ssh root@${IP} "systemctl is-active authelia" 2>/dev/null)
if [ "${SVC_STATUS}" = "active" ]; then
    echo "  ✓ Authelia service is active"
else
    echo "  ✗ Authelia service is ${SVC_STATUS}"
    echo "    Check logs: ssh root@${IP} 'journalctl -u authelia -n 50 --no-pager'"
    exit 1
fi

# Check health endpoint
HEALTH=$(ssh root@${IP} "curl -sf http://localhost:${AUTHELIA_PORT}/api/health" 2>/dev/null)
if echo "${HEALTH}" | grep -qi "ok"; then
    echo "  ✓ Health endpoint responding: ${HEALTH}"
else
    echo "  ✗ Health endpoint not responding"
    echo "    Response: ${HEALTH}"
    echo "    Check logs: ssh root@${IP} 'journalctl -u authelia -n 50 --no-pager'"
    exit 1
fi

# Verify SQLite created on data mount
if ssh root@${IP} "[ -f /mnt/data/db.sqlite3 ]"; then
    echo "  ✓ SQLite database created at /mnt/data/db.sqlite3"
else
    echo "  ⚠ SQLite database not yet created (may appear after first request)"
fi

echo ""
echo "  ═══════════════════════════════════════════════════════════"
echo "  ✓ Authelia v${AUTHELIA_VERSION} installed and running on CT-${CTID} (${IP}:${AUTHELIA_PORT})"
echo "  ═══════════════════════════════════════════════════════════"
echo ""
echo "  IMPORTANT: Before testing login, generate a real password hash:"
echo "    ssh root@${IP} \"authelia crypto hash generate argon2\""
echo "    Edit /mnt/config/users_database.yml and replace the placeholder."
echo ""
echo "Next: Stage 3 — DNS + Traefik integration"
echo "  1. Add Pi-hole DNS: auth.cogmai.com → 10.10.100.55"
echo "  2. Add Traefik routers + ForwardAuth middleware"
echo "  3. Add Cloudflare Tunnel route"
