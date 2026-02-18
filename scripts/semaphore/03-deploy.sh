#!/bin/bash
# 03-deploy.sh — Deploy Semaphore via Ansible playbook
# Run from: workstation (proxima-centauri)
#
# Runs the Ansible role that installs and configures Semaphore.
# Verifies the API is responding before declaring success.
#
set -euo pipefail

source "$(dirname "$0")/config.sh"

echo "=== Step 3: Ansible Deployment ==="

# --- Pre-flight ---
if ! ssh -o ConnectTimeout=5 root@${IP} "true" 2>/dev/null; then
    echo "  ✗ Cannot SSH to root@${IP}. Run 02-bootstrap-ssh.sh first."
    exit 1
fi

if [ ! -f "${ANSIBLE_DIR}/playbooks/deploy-semaphore.yml" ]; then
    echo "  ✗ Playbook not found: ${ANSIBLE_DIR}/playbooks/deploy-semaphore.yml"
    exit 1
fi

# --- Deploy ---
echo "  Running: ansible-playbook playbooks/deploy-semaphore.yml"
echo ""

cd "${ANSIBLE_DIR}"
ansible-playbook playbooks/deploy-semaphore.yml
ANSIBLE_RC=$?

echo ""
if [ ${ANSIBLE_RC} -ne 0 ]; then
    echo "  ✗ Ansible playbook failed (exit code ${ANSIBLE_RC})"
    exit 1
fi

# --- Verify API is up ---
echo "  Checking API..."
PING=$(curl -s --connect-timeout 5 "http://${IP}:${SEMAPHORE_PORT}/api/ping" 2>/dev/null)
if echo "${PING}" | grep -q "pong"; then
    echo "  ✓ Semaphore API responding: ${PING}"
else
    echo "  ✗ Semaphore API not responding (got: '${PING}')"
    exit 1
fi

echo ""
echo "  ✓ Semaphore deployed and running"
echo ""
echo "Next: bash scripts/semaphore/04-verify.sh"
