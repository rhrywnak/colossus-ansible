#!/bin/bash
# deploy-all.sh — Run the complete Semaphore deployment workflow
# Run from: workstation (proxima-centauri)
#
# Executes each step in order, stopping on first failure.
# Each step verifies itself before proceeding.
#
# Workflow:
#   00-destroy.sh        → Remove existing CT-315
#   01-create.sh         → Create fresh LXC on pve-3
#   02-bootstrap-ssh.sh  → Install SSH, inject key
#   03-deploy.sh         → Ansible role deployment
#   04-verify.sh         → Full validation
#
# Usage:
#   cd ~/colossus-ansible
#   bash scripts/semaphore/deploy-all.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==========================================="
echo " Semaphore — Full Deployment Workflow"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "==========================================="
echo ""

STEPS=(
    "00-destroy.sh"
    "01-create.sh"
    "02-bootstrap-ssh.sh"
    "03-deploy.sh"
    "04-verify.sh"
)

for STEP in "${STEPS[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    bash "${SCRIPT_DIR}/${STEP}"
    echo ""
done

echo "==========================================="
echo " Deployment complete"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "==========================================="
