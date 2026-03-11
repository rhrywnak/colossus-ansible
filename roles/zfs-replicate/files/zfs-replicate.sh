#!/usr/bin/env bash
#
# zfs-replicate.sh — Replicate local ZFS datasets to TrueNAS
#
# Deployed by Ansible role: zfs-replicate
# Runs daily via systemd timer
#
# Usage: zfs-replicate.sh /etc/zfs-replicate/datasets.conf
#
set -euo pipefail

# ── Configuration ──────────────────────────────────────────
CONFIG_FILE="${1:?Usage: $0 <config-file>}"
TRUENAS_HOST="10.10.0.38"
TRUENAS_USER="root"
TRUENAS_BASE="Pool-1/backups/zfs-replica"
SNAP_PREFIX="autoreplica"
LOCAL_RETENTION=7     # Keep 7 daily snapshots locally
REMOTE_RETENTION=14   # Keep 14 daily snapshots on TrueNAS
DATE=$(date +%Y-%m-%d)
SNAP_NAME="${SNAP_PREFIX}-${DATE}"
SSH_OPTS="-o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

# TrueNAS has /usr/sbin/zfs not in default PATH
REMOTE_ZFS="/usr/sbin/zfs"

# ── Logging ────────────────────────────────────────────────
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
err()  { log "ERROR: $*" >&2; }
die()  { err "$*"; exit 1; }

# ── Validate ───────────────────────────────────────────────
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"

# Test SSH connectivity
ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" 'echo ok' >/dev/null 2>&1 \
    || die "Cannot SSH to TrueNAS at ${TRUENAS_HOST}"

# ── Read dataset list ──────────────────────────────────────
# Config format: one line per dataset
#   <local_dataset> <remote_name>
# Example:
#   prod-zfs/postgres pve-1/postgres
#   prod-zfs/neo4j pve-1/neo4j
DATASETS=()
while IFS=' ' read -r local_ds remote_name || [[ -n "$local_ds" ]]; do
    # Skip comments and blank lines
    [[ -z "$local_ds" || "$local_ds" == \#* ]] && continue
    DATASETS+=("${local_ds}|${remote_name}")
done < "$CONFIG_FILE"

[[ ${#DATASETS[@]} -gt 0 ]] || die "No datasets found in $CONFIG_FILE"

log "Starting ZFS replication: ${#DATASETS[@]} datasets → ${TRUENAS_HOST}"
FAILURES=0

# ── Process each dataset ───────────────────────────────────
for entry in "${DATASETS[@]}"; do
    IFS='|' read -r LOCAL_DS REMOTE_NAME <<< "$entry"
    REMOTE_DS="${TRUENAS_BASE}/${REMOTE_NAME}"
    FULL_SNAP="${LOCAL_DS}@${SNAP_NAME}"

    log "────────────────────────────────────────"
    log "Dataset: ${LOCAL_DS} → ${REMOTE_DS}"

    # ── Step 1: Create local snapshot ──────────────────────
    if zfs list -t snapshot -o name -H "${FULL_SNAP}" >/dev/null 2>&1; then
        log "  Snapshot ${FULL_SNAP} already exists (idempotent)"
    else
        log "  Creating snapshot: ${FULL_SNAP}"
        if ! zfs snapshot "${FULL_SNAP}"; then
            err "  Failed to create snapshot ${FULL_SNAP}"
            FAILURES=$((FAILURES + 1))
            continue
        fi
    fi

    # ── Step 2: Determine send type ───────────────────────
    # Check if remote dataset exists and has snapshots from us
    REMOTE_SNAPS=$(ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" \
        "${REMOTE_ZFS} list -t snapshot -o name -H -r '${REMOTE_DS}' 2>/dev/null | grep '@${SNAP_PREFIX}-' || true")

    if [[ -z "$REMOTE_SNAPS" ]]; then
        # No remote snapshots — check if remote dataset exists at all
        if ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" \
            "${REMOTE_ZFS} list -o name -H '${REMOTE_DS}' >/dev/null 2>&1"; then
            # Dataset exists but has no matching snapshots — need to destroy and re-send
            log "  Remote dataset exists but has no replica snapshots. Destroying for clean full send."
            ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" \
                "${REMOTE_ZFS} destroy -r '${REMOTE_DS}'"
        fi

        # Full send
        log "  Performing FULL send (first replication)"
        if ! zfs send "${FULL_SNAP}" | \
            ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" \
            "${REMOTE_ZFS} receive -F '${REMOTE_DS}'"; then
            err "  Full send FAILED for ${LOCAL_DS}"
            FAILURES=$((FAILURES + 1))
            continue
        fi
        log "  Full send complete"
    else
        # Find the latest common snapshot
        LOCAL_SNAPS=$(zfs list -t snapshot -o name -H -r "${LOCAL_DS}" | grep "@${SNAP_PREFIX}-" | sort)
        LATEST_COMMON=""

        # Walk remote snapshots (newest first) to find one that also exists locally
        for remote_snap_full in $(echo "$REMOTE_SNAPS" | sort -r); do
            snap_tag="${remote_snap_full##*@}"
            if echo "$LOCAL_SNAPS" | grep -q "@${snap_tag}$"; then
                LATEST_COMMON="${snap_tag}"
                break
            fi
        done

        if [[ -z "$LATEST_COMMON" ]]; then
            # No common snapshot — must do full send
            log "  No common snapshot found. Performing FULL send (resync)"
            ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" \
                "${REMOTE_ZFS} destroy -r '${REMOTE_DS}'" 2>/dev/null || true
            if ! zfs send "${FULL_SNAP}" | \
                ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" \
                "${REMOTE_ZFS} receive -F '${REMOTE_DS}'"; then
                err "  Full resync FAILED for ${LOCAL_DS}"
                FAILURES=$((FAILURES + 1))
                continue
            fi
            log "  Full resync complete"
        elif [[ "$LATEST_COMMON" == "$SNAP_NAME" ]]; then
            log "  Already replicated today (${SNAP_NAME}). Skipping."
            # Still run pruning below
        else
            # Incremental send from latest common to today
            log "  Incremental send: @${LATEST_COMMON} → @${SNAP_NAME}"
            if ! zfs send -i "${LOCAL_DS}@${LATEST_COMMON}" "${FULL_SNAP}" | \
                ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" \
                "${REMOTE_ZFS} receive -F '${REMOTE_DS}'"; then
                err "  Incremental send FAILED for ${LOCAL_DS}"
                FAILURES=$((FAILURES + 1))
                continue
            fi
            log "  Incremental send complete"
        fi
    fi

    # ── Step 3: Prune old local snapshots ──────────────────
    LOCAL_REPLICA_SNAPS=$(zfs list -t snapshot -o name -H -r "${LOCAL_DS}" \
        | grep "@${SNAP_PREFIX}-" | sort)
    LOCAL_COUNT=$(echo "$LOCAL_REPLICA_SNAPS" | grep -c . || true)

    if [[ $LOCAL_COUNT -gt $LOCAL_RETENTION ]]; then
        PRUNE_COUNT=$((LOCAL_COUNT - LOCAL_RETENTION))
        log "  Pruning ${PRUNE_COUNT} old local snapshots (keeping ${LOCAL_RETENTION})"
        echo "$LOCAL_REPLICA_SNAPS" | head -n "$PRUNE_COUNT" | while read -r snap; do
            log "    Destroying: ${snap}"
            zfs destroy "$snap" || err "    Failed to destroy ${snap}"
        done
    fi

    # ── Step 4: Prune old remote snapshots ─────────────────
    REMOTE_REPLICA_SNAPS=$(ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" \
        "${REMOTE_ZFS} list -t snapshot -o name -H -r '${REMOTE_DS}' | grep '@${SNAP_PREFIX}-' | sort" 2>/dev/null || true)
    REMOTE_COUNT=$(echo "$REMOTE_REPLICA_SNAPS" | grep -c . || true)

    if [[ $REMOTE_COUNT -gt $REMOTE_RETENTION ]]; then
        PRUNE_COUNT=$((REMOTE_COUNT - REMOTE_RETENTION))
        log "  Pruning ${PRUNE_COUNT} old remote snapshots (keeping ${REMOTE_RETENTION})"
        echo "$REMOTE_REPLICA_SNAPS" | head -n "$PRUNE_COUNT" | while read -r snap; do
            log "    Destroying remote: ${snap}"
            ssh $SSH_OPTS "${TRUENAS_USER}@${TRUENAS_HOST}" \
                "${REMOTE_ZFS} destroy '${snap}'" || err "    Failed to destroy remote ${snap}"
        done
    fi

    log "  ✅ ${LOCAL_DS} complete"
done

log "────────────────────────────────────────"
if [[ $FAILURES -gt 0 ]]; then
    log "⚠️  Replication finished with ${FAILURES} failure(s) out of ${#DATASETS[@]} datasets"
    exit 1
else
    log "✅ All ${#DATASETS[@]} datasets replicated successfully"
    exit 0
fi
