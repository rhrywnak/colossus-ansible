#!/bin/bash
# config.sh — Shared configuration for Authelia deployment scripts
# Sourced by all scripts in this directory. Edit values here, not in individual scripts.
#
# Pattern: matches scripts/semaphore/config.sh

PVE_HOST="root@10.10.100.5"     # pve-3 (infra node)
CTID=316
HOSTNAME=authelia
IP="10.10.100.58"
CIDR="${IP}/24"
GATEWAY="10.10.100.1"
DNS="10.10.100.53"               # Pi-hole
DOMAIN="cogmai.com"
MEMORY=256
SWAP=256
CORES=1
DISK_SIZE=4
STORAGE="local-lvm"
BRIDGE="vmbr0"
SSH_PUBKEY="${HOME}/.ssh/id_ed25519.pub"
AUTHELIA_PORT=9091

# ZFS datasets on pve-3 for externalized storage (golden rule: no data inside containers)
ZFS_PARENT="pbs-zfs/services/authelia"
ZFS_DATA="${ZFS_PARENT}/data"        # SQLite DB, logs, notification state
ZFS_CONFIG="${ZFS_PARENT}/config"    # configuration.yml, users_database.yml, secrets/

ZFS_DATA_MOUNTPOINT="/pbs-zfs/services/authelia/data"
ZFS_CONFIG_MOUNTPOINT="/pbs-zfs/services/authelia/config"

# Bind mount paths inside the container
CT_DATA_MOUNT="/mnt/data"            # → ZFS_DATA
CT_CONFIG_MOUNT="/mnt/config"        # → ZFS_CONFIG

# UID/GID mapping for unprivileged container
# Initial ownership set to root (100000:100000 on host = UID 0 inside CT).
# 02-install.sh adjusts ownership to the authelia user after APT install,
# once the actual UID is known.
CT_ROOT_UID=100000
CT_ROOT_GID=100000

# Ansible project directory (derived from script location)
ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
