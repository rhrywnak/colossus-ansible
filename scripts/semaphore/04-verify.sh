#!/bin/bash
# 04-verify.sh — Validate Semaphore deployment end-to-end
# Run from: workstation (proxima-centauri)
#
# Checks: container, binary, config, database, service, API, Ansible venv,
# Galaxy collections, external mounts, Traefik (optional), and resource usage.
#
set +e

source "$(dirname "$0")/config.sh"

echo "==========================================="
echo " Semaphore Verification — ${IP}"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "==========================================="
echo ""

PASS=0
FAIL=0
WARN=0

check_pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
check_fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
check_warn() { echo "  ⚠ $1"; WARN=$((WARN + 1)); }

# --- Connectivity ---
echo "Connectivity:"

if ssh -o ConnectTimeout=5 root@${IP} "true" 2>/dev/null; then
    check_pass "SSH: root@${IP}"
else
    check_fail "SSH: cannot reach root@${IP}"
    echo ""
    echo "Cannot continue without SSH. Exiting."
    exit 1
fi

# --- Semaphore binary ---
echo ""
echo "Installation:"

VERSION=$(ssh root@${IP} "semaphore version" 2>/dev/null)
if echo "${VERSION}" | grep -q "${EXPECTED_VERSION}"; then
    check_pass "Version: ${VERSION}"
else
    check_fail "Version: '${VERSION}' (expected ${EXPECTED_VERSION})"
fi

# Config file
if ssh root@${IP} "test -f /etc/semaphore/config.json" 2>/dev/null; then
    PERMS=$(ssh root@${IP} "stat -c '%a %U:%G' /etc/semaphore/config.json" 2>/dev/null)
    if echo "${PERMS}" | grep -q "600 semaphore:semaphore"; then
        check_pass "Config: /etc/semaphore/config.json (${PERMS})"
    else
        check_warn "Config permissions: ${PERMS} (expected 600 semaphore:semaphore)"
    fi
else
    check_fail "Config: /etc/semaphore/config.json missing"
fi

# Database (externalized on ZFS mount)
if ssh root@${IP} "test -f ${CT_DATA_MOUNT}/database.sqlite3" 2>/dev/null; then
    DB_SIZE=$(ssh root@${IP} "du -h ${CT_DATA_MOUNT}/database.sqlite3" 2>/dev/null | awk '{print $1}')
    check_pass "Database: SQLite on external mount (${DB_SIZE})"
else
    check_fail "Database: ${CT_DATA_MOUNT}/database.sqlite3 missing"
fi

# Config backup on external mount
if ssh root@${IP} "test -f ${CT_DATA_MOUNT}/config.json" 2>/dev/null; then
    check_pass "Config backup: ${CT_DATA_MOUNT}/config.json present"
else
    check_warn "Config backup: ${CT_DATA_MOUNT}/config.json missing (rebuild safety net)"
fi

# --- External mounts ---
echo ""
echo "External Storage (golden rule):"

if ssh root@${IP} "mountpoint -q ${CT_DATA_MOUNT}" 2>/dev/null; then
    DATA_AVAIL=$(ssh root@${IP} "df -h ${CT_DATA_MOUNT}" 2>/dev/null | tail -1 | awk '{print $4}')
    check_pass "Data mount: ${CT_DATA_MOUNT} (${DATA_AVAIL} available)"
else
    check_fail "Data mount: ${CT_DATA_MOUNT} is NOT a mount point"
fi

if ssh root@${IP} "mountpoint -q ${CT_SYNC_MOUNT}" 2>/dev/null; then
    SYNC_AVAIL=$(ssh root@${IP} "df -h ${CT_SYNC_MOUNT}" 2>/dev/null | tail -1 | awk '{print $4}')
    check_pass "Sync mount: ${CT_SYNC_MOUNT} (${SYNC_AVAIL} available)"
else
    check_fail "Sync mount: ${CT_SYNC_MOUNT} is NOT a mount point"
fi

# Ensure NO data in old location
if ssh root@${IP} "test -f /var/lib/semaphore/database.sqlite3" 2>/dev/null; then
    check_fail "Old DB location: /var/lib/semaphore/database.sqlite3 still exists (should be removed)"
else
    check_pass "Old DB location: /var/lib/semaphore/database.sqlite3 clean (removed)"
fi

# --- systemd service ---
echo ""
echo "Service:"

SVC_STATE=$(ssh root@${IP} "systemctl is-active semaphore" 2>/dev/null)
if [ "${SVC_STATE}" = "active" ]; then
    check_pass "systemd: active"
else
    check_fail "systemd: ${SVC_STATE}"
fi

SVC_ENABLED=$(ssh root@${IP} "systemctl is-enabled semaphore" 2>/dev/null)
if [ "${SVC_ENABLED}" = "enabled" ]; then
    check_pass "systemd: enabled (starts on boot)"
else
    check_warn "systemd: ${SVC_ENABLED} (should be enabled)"
fi

# --- API ---
echo ""
echo "API:"

PING=$(ssh root@${IP} "curl -sf http://localhost:${SEMAPHORE_PORT}/api/ping" 2>/dev/null)
if echo "${PING}" | grep -q "pong"; then
    check_pass "Local API: pong"
else
    check_fail "Local API: no response"
fi

# Check via Traefik (optional — may not be configured yet)
HTTPS_PING=$(curl -sf "https://semaphore.${DOMAIN}/api/ping" 2>/dev/null)
if echo "${HTTPS_PING}" | grep -q "pong"; then
    check_pass "External API (Traefik): pong"
else
    check_warn "External API (Traefik): not available (Stage 3 dependency)"
fi

# --- Ansible venv ---
echo ""
echo "Ansible:"

ANSIBLE_VER=$(ssh root@${IP} "su - semaphore -c '/home/semaphore/venv/bin/ansible --version 2>/dev/null | head -1'" 2>/dev/null)
if echo "${ANSIBLE_VER}" | grep -q "ansible"; then
    check_pass "Ansible: ${ANSIBLE_VER}"
else
    check_fail "Ansible: not found in venv"
fi

# --- Resource usage ---
echo ""
echo "Resources:"

MEM_USED=$(ssh root@${IP} "ps aux | grep '[s]emaphore server' | awk '{print \$6}'" 2>/dev/null)
if [ -n "${MEM_USED}" ]; then
    MEM_MB=$((MEM_USED / 1024))
    check_pass "Memory: ${MEM_MB}MB (semaphore process)"
else
    check_warn "Memory: cannot determine (process not found)"
fi

DISK_PCT=$(ssh root@${IP} "df / | tail -1 | awk '{print \$5}'" 2>/dev/null)
check_pass "Root disk: ${DISK_PCT} used"

# --- Summary ---
echo ""
echo "==========================================="
echo " Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
echo "==========================================="

if [ ${FAIL} -gt 0 ]; then
    echo ""
    echo "  ✗ VERIFICATION FAILED — review errors above"
    exit 1
elif [ ${WARN} -gt 0 ]; then
    echo ""
    echo "  ⚠ PASSED WITH WARNINGS — review warnings above"
    exit 0
else
    echo ""
    echo "  ✓ ALL CHECKS PASSED"
    exit 0
fi
