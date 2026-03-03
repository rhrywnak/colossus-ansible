#!/bin/bash
# 01-create.sh — Create Authelia LXC container on pve-3
# Run from: workstation (proxima-centauri)
#
# Creates CT-316 with Debian 12 minimal, configures ZFS datasets for
# externalized storage, adds bind mounts, starts it, verifies it's running.
#
# ZFS datasets (created if not present — idempotent):
#   pbs-zfs/services/authelia/data   → /mnt/data   (SQLite DB, logs, notifications)
#   pbs-zfs/services/authelia/config → /mnt/config  (configuration.yml, users, secrets)
#
# Does NOT install anything inside — that's 02-install.sh.
#
set -euo pipefail

source "$(dirname "$0")/config.sh"

echo "=== Step 1: Create CT-${CTID} (${HOSTNAME}) ==="

# --- Pre-flight ---
echo "  Pre-flight checks..."

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

echo "  ✓ Pre-flight passed"

# --- ZFS datasets (idempotent) ---
echo ""
echo "  Ensuring ZFS datasets exist..."
ssh ${PVE_HOST} "bash -s" << EOF
    # Create parent and children only if they don't exist
    zfs list ${ZFS_PARENT} &>/dev/null || zfs create ${ZFS_PARENT}
    zfs list ${ZFS_DATA}   &>/dev/null || zfs create ${ZFS_DATA}
    zfs list ${ZFS_CONFIG} &>/dev/null || zfs create ${ZFS_CONFIG}

    # Create secrets subdirectory on config dataset
    mkdir -p ${ZFS_CONFIG_MOUNTPOINT}/secrets

    # Set ownership for unprivileged container mapping
    # Root inside CT (UID 0) maps to UID ${CT_ROOT_UID} on host.
    # 02-install.sh will chown to the authelia user after APT creates it.
    chown -R ${CT_ROOT_UID}:${CT_ROOT_GID} ${ZFS_DATA_MOUNTPOINT}
    chown -R ${CT_ROOT_UID}:${CT_ROOT_GID} ${ZFS_CONFIG_MOUNTPOINT}

    echo "  ZFS datasets:"
    zfs list -r ${ZFS_PARENT}
EOF

# --- Discover template ---
TEMPLATE=$(ssh ${PVE_HOST} "pveam list local" 2>/dev/null | grep "debian-12-standard" | awk '{print $1}' | head -1)
if [ -z "${TEMPLATE}" ]; then
    echo "  ✗ No Debian 12 template found on pve-3"
    echo "    Fix: ssh ${PVE_HOST} 'pveam update && pveam download local debian-12-standard_12.12-1_amd64.tar.zst'"
    exit 1
fi
echo ""
echo "  Template: ${TEMPLATE}"

# --- Create container ---
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
    --unprivileged 1"

# --- Add bind mounts before starting ---
echo "  Adding bind mounts..."
ssh ${PVE_HOST} "bash -s" << EOF
    pct set ${CTID} -mp0 ${ZFS_DATA_MOUNTPOINT},mp=${CT_DATA_MOUNT}
    pct set ${CTID} -mp1 ${ZFS_CONFIG_MOUNTPOINT},mp=${CT_CONFIG_MOUNT}
    echo "  Mount points configured:"
    pct config ${CTID} | grep -E "^mp[0-9]"
EOF

# --- Start ---
echo ""
echo "  Starting CT-${CTID}..."
ssh ${PVE_HOST} "pct start ${CTID}"
sleep 5

# --- Verify: container running ---
STATUS=$(ssh ${PVE_HOST} "pct status ${CTID}" | awk '{print $2}')
if [ "${STATUS}" != "running" ]; then
    echo "  ✗ CT-${CTID} is not running (status: ${STATUS})"
    exit 1
fi
echo "  ✓ CT-${CTID} is running"

# --- Verify: gateway reachable ---
if ssh ${PVE_HOST} "pct exec ${CTID} -- ping -c 1 -W 3 ${GATEWAY}" &>/dev/null; then
    echo "  ✓ Gateway (${GATEWAY}) reachable from container"
else
    echo "  ✗ Gateway unreachable from container"
    exit 1
fi

# --- Verify: DNS reachable ---
if ssh ${PVE_HOST} "pct exec ${CTID} -- ping -c 1 -W 3 ${DNS}" &>/dev/null; then
    echo "  ✓ DNS (${DNS}) reachable from container"
else
    echo "  ✗ DNS unreachable from container"
    exit 1
fi

# --- Verify: bind mounts visible inside container ---
echo "  Verifying bind mounts inside container..."
ssh ${PVE_HOST} "pct exec ${CTID} -- ls -la ${CT_DATA_MOUNT}/"
ssh ${PVE_HOST} "pct exec ${CTID} -- ls -la ${CT_CONFIG_MOUNT}/"

echo ""
echo "  ✓ CT-${CTID} created and running at ${IP}"
echo "  ✓ ZFS bind mounts:"
echo "      ${CT_DATA_MOUNT}   → ${ZFS_DATA}   (data: SQLite, logs)"
echo "      ${CT_CONFIG_MOUNT} → ${ZFS_CONFIG} (config: YAML, secrets)"
echo ""
echo "Next: bash scripts/authelia/02-install.sh"
