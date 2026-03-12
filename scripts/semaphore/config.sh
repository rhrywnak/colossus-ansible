#!/bin/bash
# config.sh — Shared configuration for Semaphore deployment scripts
# Sourced by all scripts in this directory. Edit values here, not in individual scripts.

PVE_HOST="root@10.10.100.5"     # pve-3 (infra node)
CTID=315
HOSTNAME=semaphore
IP="10.10.100.57"
CIDR="${IP}/24"
GATEWAY="10.10.100.1"
DNS="10.10.100.53"               # Pi-hole
DOMAIN="cogmai.com"
MEMORY=512
SWAP=256
CORES=1
DISK_SIZE=4
STORAGE="local-lvm"
BRIDGE="vmbr0"
SSH_PUBKEY="${HOME}/.ssh/id_ed25519.pub"
SEMAPHORE_PORT=3000
EXPECTED_VERSION="2.17"

# ZFS datasets on pve-3 for externalized storage (golden rule: no data inside containers)
ZFS_PARENT="pbs-zfs/services/semaphore"
ZFS_DATA="${ZFS_PARENT}/data"        # SQLite DB, config.json backup, tmp
ZFS_SYNC="${ZFS_PARENT}/sync"        # Neo4j sync archive
ZFS_DATA_MOUNTPOINT="/pbs-zfs/services/semaphore/data"
ZFS_SYNC_MOUNTPOINT="/pbs-zfs/services/semaphore/sync"

# Bind mount paths inside the container
CT_DATA_MOUNT="/mnt/data"           # → ZFS_DATA
CT_SYNC_MOUNT="/opt/db-sync"        # → ZFS_SYNC (neo4j/, postgres/, qdrant/ subdirs)

# UID/GID mapping for unprivileged container
# semaphore user inside CT maps to these UIDs on the host
CT_UID=100999
CT_GID=100996

# Ansible project directory (derived from script location)
ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
