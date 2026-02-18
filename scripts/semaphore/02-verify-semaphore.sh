#!/bin/bash
# 02-verify-semaphore.sh — Validate Semaphore deployment
# Run from: workstation (proxima-centauri)
set -e

SEMAPHORE_IP="${1:-10.10.100.57}"
SEMAPHORE_PORT=3000
EXPECTED_VERSION="2.17"

echo "==========================================="
echo " Semaphore Verification — ${SEMAPHORE_IP}"
echo "==========================================="
echo ""

PASS=0
FAIL=0
WARN=0

check_pass() { echo "  ✓ $1"; ((PASS++)); }
check_fail() { echo "  ✗ $1"; ((FAIL++)); }
check_warn() { echo "  ⚠ $1"; ((WARN++)); }

# --- Container & connectivity ---
echo "Container (CT-315):"

if ssh -o ConnectTimeout=5 root@${SEMAPHORE_IP} "true" 2>/dev/null; then
    check_pass "SSH connectivity: root@${SEMAPHORE_IP}"
else
    check_fail "SSH connectivity: cannot reach root@${SEMAPHORE_IP}"
    echo ""
    echo "Cannot continue without SSH. Exiting."
    exit 1
fi

# --- Semaphore binary ---
echo ""
echo "Semaphore Installation:"

VERSION=$(ssh root@${SEMAPHORE_IP} "semaphore version" 2>/dev/null)
if echo "${VERSION}" | grep -q "${EXPECTED_VERSION}"; then
    check_pass "Version: ${VERSION}"
else
    check_fail "Version: '${VERSION}' (expected ${EXPECTED_VERSION})"
fi

# Config file permissions
if ssh root@${SEMAPHORE_IP} "test -f /etc/semaphore/config.json" 2>/dev/null; then
    PERMS=$(ssh root@${SEMAPHORE_IP} "stat -c '%a %U:%G' /etc/semaphore/config.json" 2>/dev/null)
    if echo "${PERMS}" | grep -q "600 semaphore:semaphore"; then
        check_pass "Config: /etc/semaphore/config.json (${PERMS})"
    else
        check_warn "Config permissions: ${PERMS} (expected 600 semaphore:semaphore)"
    fi
else
    check_fail "Config: /etc/semaphore/config.json missing"
fi

# SQLite database
if ssh root@${SEMAPHORE_IP} "test -f /var/lib/semaphore/database.sqlite3" 2>/dev/null; then
    DB_SIZE=$(ssh root@${SEMAPHORE_IP} "du -h /var/lib/semaphore/database.sqlite3" 2>/dev/null | awk '{print $1}')
    check_pass "Database: SQLite (${DB_SIZE})"
else
    check_fail "Database: /var/lib/semaphore/database.sqlite3 missing"
fi

# --- systemd service ---
echo ""
echo "Service:"

SVC_STATE=$(ssh root@${SEMAPHORE_IP} "systemctl is-active semaphore" 2>/dev/null)
if [ "${SVC_STATE}" = "active" ]; then
    check_pass "systemd: active (running)"
else
    check_fail "systemd: ${SVC_STATE}"
fi

SVC_ENABLED=$(ssh root@${SEMAPHORE_IP} "systemctl is-enabled semaphore" 2>/dev/null)
if [ "${SVC_ENABLED}" = "enabled" ]; then
    check_pass "Enabled on boot: yes"
else
    check_warn "Enabled on boot: ${SVC_ENABLED}"
fi

# Memory usage
MEMORY=$(ssh root@${SEMAPHORE_IP} "ps -o rss= -p \$(pgrep semaphore | head -1) 2>/dev/null" 2>/dev/null)
if [ -n "${MEMORY}" ]; then
    MEMORY_MB=$(( ${MEMORY} / 1024 ))
    check_pass "Memory: ${MEMORY_MB}MB"
fi

# --- API ---
echo ""
echo "API:"

PING_RESPONSE=$(curl -s --connect-timeout 5 "http://${SEMAPHORE_IP}:${SEMAPHORE_PORT}/api/ping" 2>/dev/null)
if echo "${PING_RESPONSE}" | grep -q "pong"; then
    check_pass "Ping: ${PING_RESPONSE}"
else
    check_fail "Ping: '${PING_RESPONSE}' (expected 'pong')"
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://${SEMAPHORE_IP}:${SEMAPHORE_PORT}/" 2>/dev/null)
if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "301" ] || [ "${HTTP_CODE}" = "302" ]; then
    check_pass "Web UI: HTTP ${HTTP_CODE}"
else
    check_fail "Web UI: HTTP ${HTTP_CODE}"
fi

# --- Ansible in venv ---
echo ""
echo "Ansible Environment:"

ANSIBLE_VER=$(ssh root@${SEMAPHORE_IP} "su -s /bin/bash semaphore -c '/home/semaphore/venv/bin/ansible --version' 2>/dev/null | head -1" 2>/dev/null)
if [ -n "${ANSIBLE_VER}" ]; then
    check_pass "Ansible: ${ANSIBLE_VER}"
else
    check_fail "Ansible: not found in venv"
fi

for COLLECTION in community.general community.proxmox ansible.posix; do
    if ssh root@${SEMAPHORE_IP} "su -s /bin/bash semaphore -c '/home/semaphore/venv/bin/ansible-galaxy collection list'" 2>/dev/null | grep -q "${COLLECTION}"; then
        check_pass "Collection: ${COLLECTION}"
    else
        check_warn "Collection: ${COLLECTION} not found"
    fi
done

# --- Traefik (optional, checked but not required) ---
echo ""
echo "Traefik Integration:"

TRAEFIK_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://semaphore.cogmai.com/api/ping" 2>/dev/null)
if [ "${TRAEFIK_CODE}" = "200" ]; then
    check_pass "HTTPS: https://semaphore.cogmai.com (HTTP ${TRAEFIK_CODE})"
else
    check_warn "HTTPS: not configured yet (HTTP ${TRAEFIK_CODE})"
fi

# --- Disk usage ---
echo ""
echo "Resources:"

DISK_USAGE=$(ssh root@${SEMAPHORE_IP} "df -h / | tail -1" 2>/dev/null | awk '{print $3 " / " $2 " (" $5 " used)"}')
if [ -n "${DISK_USAGE}" ]; then
    check_pass "Disk: ${DISK_USAGE}"
fi

# --- Summary ---
echo ""
echo "==========================================="
echo " Results: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
echo "==========================================="
echo ""

if [ $FAIL -gt 0 ]; then
    echo "⚠  Some checks failed. Review output above."
    exit 1
else
    echo "Semaphore UI is fully operational."
    echo ""
    echo "  Direct: http://${SEMAPHORE_IP}:${SEMAPHORE_PORT}"
    echo "  HTTPS:  https://semaphore.cogmai.com (after Stage 3)"
    echo ""
    echo "Next steps:"
    echo "  1. Stage 3: DNS & Traefik integration"
    echo "  2. Stage 4: Alloy agent + PBS backup"
    echo "  3. Stage 5: Configure project in Semaphore UI"
fi
