#!/bin/bash
# 04-verify.sh — Validate Semaphore deployment end-to-end
# Run from: workstation (proxima-centauri)
#
# Checks: container, binary, config, database, service, API, Ansible venv,
# Galaxy collections, Traefik (optional), and resource usage.
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

# Database
if ssh root@${IP} "test -f /var/lib/semaphore/database.sqlite3" 2>/dev/null; then
    DB_SIZE=$(ssh root@${IP} "du -h /var/lib/semaphore/database.sqlite3" 2>/dev/null | awk '{print $1}')
    check_pass "Database: SQLite (${DB_SIZE})"
else
    check_fail "Database: /var/lib/semaphore/database.sqlite3 missing"
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
    check_pass "Boot enabled: yes"
else
    check_warn "Boot enabled: ${SVC_ENABLED}"
fi

MEMORY_KB=$(ssh root@${IP} "ps -o rss= -p \$(pgrep -x semaphore | head -1) 2>/dev/null" 2>/dev/null || echo "")
if [ -n "${MEMORY_KB}" ]; then
    MEMORY_MB=$(( ${MEMORY_KB} / 1024 ))
    check_pass "Process memory: ${MEMORY_MB}MB"
fi

# --- API ---
echo ""
echo "API:"

PING=$(curl -s --connect-timeout 5 "http://${IP}:${SEMAPHORE_PORT}/api/ping" 2>/dev/null)
if echo "${PING}" | grep -q "pong"; then
    check_pass "Ping: ${PING}"
else
    check_fail "Ping: '${PING}' (expected 'pong')"
fi

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "http://${IP}:${SEMAPHORE_PORT}/" 2>/dev/null)
if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "301" ] || [ "${HTTP_CODE}" = "302" ]; then
    check_pass "Web UI: HTTP ${HTTP_CODE}"
else
    check_fail "Web UI: HTTP ${HTTP_CODE}"
fi

# --- Ansible environment ---
echo ""
echo "Ansible:"

ANSIBLE_VER=$(ssh root@${IP} "su -s /bin/bash semaphore -c '/home/semaphore/venv/bin/ansible --version' 2>/dev/null | head -1" 2>/dev/null)
if [ -n "${ANSIBLE_VER}" ]; then
    check_pass "${ANSIBLE_VER}"
else
    check_fail "Ansible not found in venv"
fi

for COLLECTION in community.general community.proxmox ansible.posix; do
    if ssh root@${IP} "su -s /bin/bash semaphore -c '/home/semaphore/venv/bin/ansible-galaxy collection list'" 2>/dev/null | grep -q "${COLLECTION}"; then
        check_pass "Collection: ${COLLECTION}"
    else
        check_warn "Collection: ${COLLECTION} not found"
    fi
done

# --- Traefik (optional) ---
echo ""
echo "Traefik (optional):"

TRAEFIK_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://semaphore.${DOMAIN}/api/ping" 2>/dev/null)
if [ "${TRAEFIK_CODE}" = "200" ]; then
    check_pass "HTTPS: https://semaphore.${DOMAIN}"
else
    check_warn "HTTPS: not configured yet (Stage 3)"
fi

# --- Resources ---
echo ""
echo "Resources:"

DISK=$(ssh root@${IP} "df -h / | tail -1" 2>/dev/null | awk '{print $3 " / " $2 " (" $5 " used)"}')
if [ -n "${DISK}" ]; then
    check_pass "Disk: ${DISK}"
fi

MEM=$(ssh root@${IP} "free -m | grep Mem" 2>/dev/null | awk '{print $3 "MB / " $2 "MB"}')
if [ -n "${MEM}" ]; then
    check_pass "Memory: ${MEM}"
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
    echo "  Direct: http://${IP}:${SEMAPHORE_PORT}"
    echo "  HTTPS:  https://semaphore.${DOMAIN} (after Stage 3)"
    echo ""
fi
