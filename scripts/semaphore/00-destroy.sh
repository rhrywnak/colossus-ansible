#!/bin/bash
# 00-destroy.sh — Destroy existing Semaphore LXC container
# Run from: workstation (proxima-centauri)
#
# Safe to run if CT-315 doesn't exist (exits 0).
# Clears SSH known_hosts entry for clean rebuild.
#
# IMPORTANT: ZFS datasets are NOT destroyed. This is intentional.
# The data (SQLite DB, config, sync archive) persists across rebuilds.
# To truly wipe everything: zfs destroy -r pbs-zfs/services/semaphore
#
set -euo pipefail

source "$(dirname "$0")/config.sh"

echo "=== Step 0: Destroy CT-${CTID} ==="

if ssh ${PVE_HOST} "pct status ${CTID}" &>/dev/null; then
    echo "  CT-${CTID} exists — stopping and destroying..."
    ssh ${PVE_HOST} "pct stop ${CTID} 2>/dev/null || true; pct destroy ${CTID}"
    echo "  CT-${CTID} destroyed"
else
    echo "  CT-${CTID} does not exist — nothing to destroy"
fi

# Clear stale host key
ssh-keygen -f "${HOME}/.ssh/known_hosts" -R "${IP}" 2>/dev/null || true
echo "  SSH host key cleared for ${IP}"

# Report ZFS dataset status (not destroyed — data persists)
echo ""
echo "  ZFS datasets preserved (data survives rebuild):"
ssh ${PVE_HOST} "zfs list -r ${ZFS_PARENT} 2>/dev/null" || echo "    (no datasets found)"

# --- Verify ---
if ssh ${PVE_HOST} "pct status ${CTID}" &>/dev/null; then
    echo "  ✗ FAILED: CT-${CTID} still exists"
    exit 1
fi

echo ""
echo "  ✓ CT-${CTID} destroyed — ZFS data preserved — ready for fresh create"
echo ""
echo "Next: bash scripts/semaphore/01-create.sh"
