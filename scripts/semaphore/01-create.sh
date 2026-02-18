#!/bin/bash
# 01-create.sh — Create Semaphore LXC container on pve-3
# Run from: workstation (proxima-centauri)
#
# Creates CT-315 with Debian 12 minimal, starts it, verifies it's running.
# Does NOT install anything inside — that's for later steps.
#
set -euo pipefail

source "$(dirname "$0")/config.sh"

echo "=== Step 1: Create CT-${CTID} ==="

# --- Pre-flight ---
if [ ! -f "${SSH_PUBKEY}" ]; then
    echo "  ✗ SSH public key not found: ${SSH_PUBKEY}"
    exit 1
fi

if ! ssh -o ConnectTimeout=5 ${PVE_HOST} "true" 2>/dev/null; then
    echo "  ✗ Cannot reach ${PVE_HOST}"
    exit 1
fi

if ssh ${PVE_HOST} "pct status ${CTID}" &>/dev/null; then
    echo "  ✗ CT-${CTID} already exists. Run 00-destroy.sh first."
    exit 1
fi

# --- Discover template ---
TEMPLATE=$(ssh ${PVE_HOST} "pveam list local" 2>/dev/null | grep "debian-12-standard" | awk '{print $1}' | head -1)
if [ -z "${TEMPLATE}" ]; then
    echo "  ✗ No Debian 12 template found on pve-3"
    echo "    Fix: ssh ${PVE_HOST} 'pveam update && pveam download local debian-12-standard_12.12-1_amd64.tar.zst'"
    exit 1
fi
echo "  Template: ${TEMPLATE}"

# --- Create ---
echo "  Creating CT-${CTID} (${HOSTNAME})..."
ssh ${PVE_HOST} "pct create ${CTID} ${TEMPLATE} \
    --hostname ${HOSTNAME} \
    --cores ${CORES} \
    --memory ${MEMORY} \
    --swap ${SWAP} \
    --rootfs ${STORAGE}:${DISK_SIZE} \
    --net0 name=eth0,bridge=${BRIDGE},ip=${CIDR},gw=${GATEWAY} \
    --nameserver ${DNS} \
   --searchdomain ${DOMAIN} \
    --onboot 1 \
    --start 1 \
    --unprivileged 1"

echo "  Waiting for container..."
sleep 5

# --- Verify ---
STATUS=$(ssh ${PVE_HOST} "pct status ${CTID}" | awk '{print $2}')
if [ "${STATUS}" != "running" ]; then
    echo "  ✗ CT-${CTID} is not running (status: ${STATUS})"
    exit 1
fi

if ssh ${PVE_HOST} "pct exec ${CTID} -- ping -c 1 -W 3 ${GATEWAY}" &>/dev/null; then
    echo "  ✓ Gateway reachable from container"
else
    echo "  ✗ Gateway unreachable from container"
    exit 1
fi

echo ""
echo "  ✓ CT-${CTID} created and running at ${IP}"
echo ""
echo "Next: bash scripts/semaphore/02-bootstrap-ssh.sh"
