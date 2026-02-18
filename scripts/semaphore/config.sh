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

# Ansible project directory (derived from script location)
ANSIBLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
