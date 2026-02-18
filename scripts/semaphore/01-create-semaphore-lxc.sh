#!/bin/bash
# 01-create-semaphore-lxc.sh — Create Semaphore LXC container on pve-3
# Run on: pve-3
#
# After this script completes:
#   1. From workstation: inject SSH key (see instructions at end)
#   2. From workstation: ansible-playbook playbooks/deploy-semaphore.yml
#
set -euo pipefail

CTID=315
HOSTNAME=semaphore
STORAGE=local-lvm
MEMORY=512
CORES=1
DISK_SIZE=4
IP="10.10.100.57/24"
GATEWAY="10.10.100.1"
DNS="10.10.100.53"
DOMAIN="cogmai.com"
BRIDGE="vmbr0"

# --- Template discovery ---
TEMPLATE=$(pveam list local 2>/dev/null | grep "debian-12-standard" | awk '{print $1}' | head -1)

if [ -z "$TEMPLATE" ]; then
    echo "ERROR: No Debian 12 template found."
    echo "Download one with:"
    echo "  pveam update"
    echo "  pveam download local debian-12-standard_12.12-1_amd64.tar.zst"
    echo ""
    echo "Available templates:"
    pveam list local
    exit 1
fi

echo "Using template: ${TEMPLATE}"

# --- Pre-flight ---
echo ""
echo "=== Creating Semaphore LXC container ==="
echo "  CTID:     ${CTID}"
echo "  Hostname: ${HOSTNAME}"
echo "  IP:       ${IP}"
echo "  Gateway:  ${GATEWAY}"
echo "  DNS:      ${DNS}"
echo "  Memory:   ${MEMORY}MB"
echo "  Disk:     ${DISK_SIZE}GB"
echo ""

if pct status $CTID &>/dev/null; then
    echo "ERROR: CTID ${CTID} already exists"
    pct status $CTID
    exit 1
fi

# --- Create container ---
pct create $CTID "$TEMPLATE" \
    --hostname $HOSTNAME \
    --storage $STORAGE \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --cores $CORES \
    --memory $MEMORY \
    --swap 256 \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}" \
    --nameserver "${DNS}" \
    --searchdomain "${DOMAIN}" \
    --unprivileged 1 \
    --onboot 1 \
    --start 1

echo ""
echo "Waiting for container to start..."
sleep 3

# --- Install SSH and prepare for key injection ---
echo ""
echo "=== Bootstrapping SSH ==="

pct exec $CTID -- bash -c '
    apt-get update -qq
    apt-get install -y -qq openssh-server > /dev/null
    systemctl enable --now ssh
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    sed -i "s/^#PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
    systemctl restart ssh
'

echo "  SSH installed and configured (key-only auth)"

# --- Verify container ---
echo ""
echo "=== Container created ==="
echo ""
pct config $CTID
echo ""

# --- Network test from inside container ---
echo "=== Network verification ==="
if pct exec $CTID -- ping -c 1 -W 3 google.com &>/dev/null; then
    echo "  ✓ DNS resolution working"
else
    echo "  ✗ DNS resolution failed — check Pi-hole (${DNS})"
fi

if pct exec $CTID -- ping -c 1 -W 3 ${GATEWAY%%/*} &>/dev/null; then
    echo "  ✓ Gateway reachable"
else
    echo "  ✗ Gateway unreachable"
fi

echo ""
echo "==========================================="
echo " CT-${CTID} (${HOSTNAME}) created successfully"
echo "==========================================="
echo ""
echo "Next steps — from workstation (proxima-centauri):"
echo ""
echo "  # 1. Clear old host key (if rebuilding)"
echo "  ssh-keygen -f ~/.ssh/known_hosts -R 10.10.100.57"
echo ""
echo "  # 2. Inject SSH public key"
echo "  cat ~/.ssh/id_ed25519.pub | ssh root@10.10.100.5 \\"
echo "    \"pct exec ${CTID} -- bash -c 'cat > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys'\""
echo ""
echo "  # 3. Verify SSH access"
echo "  ssh -o StrictHostKeyChecking=accept-new root@10.10.100.57 hostname"
echo ""
echo "  # 4. Deploy Semaphore via Ansible"
echo "  cd ~/colossus-ansible"
echo "  ansible-playbook playbooks/deploy-semaphore.yml"
echo ""
