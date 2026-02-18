#!/bin/bash
# 02-bootstrap-ssh.sh — Install SSH and inject key into CT-315
# Run from: workstation (proxima-centauri)
#
# Installs openssh-server via pct exec, injects public key (no passwords),
# locks down to key-only auth, verifies direct SSH from workstation.
#
set -euo pipefail

source "$(dirname "$0")/config.sh"

echo "=== Step 2: Bootstrap SSH ==="

# --- Pre-flight ---
STATUS=$(ssh ${PVE_HOST} "pct status ${CTID}" 2>/dev/null | awk '{print $2}')
if [ "${STATUS}" != "running" ]; then
    echo "  ✗ CT-${CTID} is not running (status: ${STATUS}). Run 01-create.sh first."
    exit 1
fi

if [ ! -f "${SSH_PUBKEY}" ]; then
    echo "  ✗ SSH public key not found: ${SSH_PUBKEY}"
    exit 1
fi

# --- Install openssh-server ---
echo "  Installing openssh-server..."
ssh ${PVE_HOST} "pct exec ${CTID} -- bash -c '
    apt-get update -qq
    apt-get install -y -qq openssh-server > /dev/null
    systemctl enable --now ssh
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    sed -i \"s/^#PermitRootLogin.*/PermitRootLogin prohibit-password/\" /etc/ssh/sshd_config
    systemctl restart ssh
'" 2>/dev/null

# --- Inject SSH key ---
echo "  Injecting SSH public key..."
cat "${SSH_PUBKEY}" | ssh ${PVE_HOST} \
    "pct exec ${CTID} -- bash -c 'cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'"

# --- Verify direct SSH from workstation ---
echo "  Verifying SSH connectivity..."
REMOTE_HOSTNAME=$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 root@${IP} "hostname" 2>/dev/null)
if [ "${REMOTE_HOSTNAME}" != "${HOSTNAME}" ]; then
    echo "  ✗ SSH failed — got '${REMOTE_HOSTNAME}' (expected '${HOSTNAME}')"
    exit 1
fi

# --- Verify DNS from inside container ---
if ssh root@${IP} "ping -c 1 -W 3 google.com" &>/dev/null; then
    echo "  ✓ DNS resolution working"
else
    echo "  ⚠ DNS resolution failed (non-fatal, check Pi-hole)"
fi

echo ""
echo "  ✓ SSH key deployed — root@${IP} accessible"
echo ""
echo "Next: bash scripts/semaphore/03-deploy.sh"
