#!/usr/bin/env bash
# cleanup-builds.sh — Clean up podman build artifacts on the workstation
#
# Usage:
#   ./cleanup-builds.sh          # Interactive — shows what will be removed, asks to proceed
#   ./cleanup-builds.sh --force  # No prompts — just clean
#
# What it cleans:
#   1. Dangling images (untagged intermediate build layers)
#   2. Old versioned images (keeps latest tag + last 3 versions)
#   3. Build cache
#   4. Stopped containers
#
# What it does NOT touch:
#   - Running containers
#   - Images tagged :latest
#   - The 3 most recent versioned images per repository

set -euo pipefail

FORCE="${1:-}"
REGISTRY="ghcr.io/rhrywnak"
KEEP_VERSIONS=3

echo "============================================"
echo " Colossus Build Cleanup"
echo "============================================"
echo ""

# ── Show current disk usage ──────────────────────────────────
echo "== Current podman disk usage =="
podman system df
echo ""

# ── Remove stopped containers ────────────────────────────────
STOPPED=$(podman ps -a --filter "status=exited" --filter "status=created" -q | wc -l)
echo "== Stopped containers: ${STOPPED} =="
if [[ ${STOPPED} -gt 0 ]]; then
    if [[ "${FORCE}" == "--force" ]] || { echo "Remove stopped containers? [y/N]" && read -r ans && [[ "$ans" =~ ^[Yy] ]]; }; then
        podman container prune -f
        echo "  ✓ Removed stopped containers"
    else
        echo "  Skipped"
    fi
fi
echo ""

# ── Remove dangling images ───────────────────────────────────
DANGLING=$(podman images --filter "dangling=true" -q | wc -l)
echo "== Dangling images (untagged build layers): ${DANGLING} =="
if [[ ${DANGLING} -gt 0 ]]; then
    if [[ "${FORCE}" == "--force" ]] || { echo "Remove dangling images? [y/N]" && read -r ans && [[ "$ans" =~ ^[Yy] ]]; }; then
        podman image prune -f
        echo "  ✓ Removed dangling images"
    else
        echo "  Skipped"
    fi
fi
echo ""

# ── Remove old versioned images (keep last N) ────────────────
echo "== Old versioned images (keeping last ${KEEP_VERSIONS}) =="
for REPO in "${REGISTRY}/colossus-backend" "${REGISTRY}/colossus-frontend"; do
    # Get all versioned tags (exclude "latest"), sorted newest first
    TAGS=$(podman images --format "{{.Tag}} {{.CreatedAt}}" "${REPO}" 2>/dev/null \
        | grep -v "latest" \
        | grep -v "<none>" \
        | sort -k2 -r \
        | awk '{print $1}')

    COUNT=0
    REMOVE_TAGS=()
    for TAG in ${TAGS}; do
        COUNT=$((COUNT + 1))
        if [[ ${COUNT} -gt ${KEEP_VERSIONS} ]]; then
            REMOVE_TAGS+=("${TAG}")
        fi
    done

    if [[ ${#REMOVE_TAGS[@]} -gt 0 ]]; then
        echo "  ${REPO}:"
        echo "    Keeping: $(echo "${TAGS}" | head -${KEEP_VERSIONS} | tr '\n' ' ')"
        echo "    Removing: ${REMOVE_TAGS[*]}"
        if [[ "${FORCE}" == "--force" ]] || { echo "    Remove these? [y/N]" && read -r ans && [[ "$ans" =~ ^[Yy] ]]; }; then
            for TAG in "${REMOVE_TAGS[@]}"; do
                podman rmi "${REPO}:${TAG}" 2>/dev/null || true
            done
            echo "    ✓ Removed ${#REMOVE_TAGS[@]} old images"
        else
            echo "    Skipped"
        fi
    else
        echo "  ${REPO}: nothing to remove (${COUNT} versions, keeping ${KEEP_VERSIONS})"
    fi
done
echo ""

# ── Remove build cache ───────────────────────────────────────
echo "== Build cache =="
if [[ "${FORCE}" == "--force" ]] || { echo "Remove all build cache? [y/N]" && read -r ans && [[ "$ans" =~ ^[Yy] ]]; }; then
    podman builder prune -a -f
    echo "  ✓ Removed build cache"
else
    echo "  Skipped"
fi
echo ""

# ── Final disk usage ─────────────────────────────────────────
echo "== Disk usage after cleanup =="
podman system df
echo ""
echo "============================================"
echo " Cleanup complete"
echo "============================================"
