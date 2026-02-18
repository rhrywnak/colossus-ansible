#!/bin/bash
# 00-destroy-semaphore-lxc.sh — Destroy Semaphore LXC container on pve-3
# Run on: pve-3
#
# Use this to tear down CT-315 for clean-slate rebuild.
# After destroying, re-run 01-create-semaphore-lxc.sh
#
set -euo pipefail

CTID=315

echo "=== Destroying Semaphore LXC container ==="
echo "  CTID: ${CTID}"
echo ""

if ! pct status $CTID &>/dev/null; then
    echo "CTID ${CTID} does not exist. Nothing to destroy."
    exit 0
fi

pct status $CTID

read -p "Destroy CT-${CTID}? This is irreversible. (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "Stopping CT-${CTID}..."
pct stop $CTID 2>/dev/null || true

echo "Destroying CT-${CTID}..."
pct destroy $CTID

echo ""
echo "CT-${CTID} destroyed."
echo ""
echo "Next steps — from workstation (proxima-centauri):"
echo "  ssh-keygen -f ~/.ssh/known_hosts -R 10.10.100.57"
echo ""
echo "Then on pve-3:"
echo "  bash 01-create-semaphore-lxc.sh"
