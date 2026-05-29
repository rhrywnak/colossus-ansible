#!/usr/bin/env bash
# build-release.sh — Build and push Colossus-Legal container images
#
# Usage:
#   ./scripts/build-release.sh v0.2.0
#   ./scripts/build-release.sh v0.2.0 --no-push   # Build only, don't push
#
# Prerequisites:
#   - Podman installed
#   - Logged in to ghcr.io: podman login ghcr.io
#   - Source code available at COLOSSUS_LEGAL_SRC (or default ~/Projects/colossus-legal)
#
# Project layout expected:
#   colossus-legal/
#   ├── backend/
#   │   ├── Dockerfile          # Multi-stage: ubuntu:24.04 → ubuntu:24.04
#   │   ├── Cargo.toml
#   │   ├── Cargo.lock
#   │   └── src/
#   └── frontend/
#       ├── Dockerfile          # Multi-stage: node:20 → nginx:1.27
#       ├── docker-entrypoint.sh
#       ├── nginx.conf
#       ├── package.json
#       ├── package-lock.json
#       └── src/
#
# Each Dockerfile expects its own component directory as the build context.
# Cargo fetches colossus-rs crates directly from GitHub during the build
# (both repos are public).
#
# NOTE: --no-cache is used on all builds to prevent Podman from serving
# stale layers. Without this, code changes may not appear in the image.

set -euo pipefail

# ── Configuration ────────────────────────────────────────────
VERSION="${1:?Usage: $0 <version> [--no-push]}"
NO_PUSH="${2:-}"

REGISTRY="ghcr.io/rhrywnak"
COLOSSUS_LEGAL_SRC="${COLOSSUS_LEGAL_SRC:-${HOME}/Projects/colossus-legal}"

BACKEND_IMAGE="${REGISTRY}/colossus-backend"
FRONTEND_IMAGE="${REGISTRY}/colossus-frontend"

# ── Validation ───────────────────────────────────────────────
if [[ ! -f "${COLOSSUS_LEGAL_SRC}/backend/Dockerfile" ]]; then
    echo "ERROR: Cannot find ${COLOSSUS_LEGAL_SRC}/backend/Dockerfile"
    echo "Set COLOSSUS_LEGAL_SRC to your colossus-legal repo root."
    exit 1
fi

if [[ ! -f "${COLOSSUS_LEGAL_SRC}/frontend/Dockerfile" ]]; then
    echo "ERROR: Cannot find ${COLOSSUS_LEGAL_SRC}/frontend/Dockerfile"
    exit 1
fi

# ── Ensure source is up to date ──────────────────────────────
echo "== Checking source repo =="
cd "${COLOSSUS_LEGAL_SRC}"
CURRENT_BRANCH=$(git branch --show-current)
echo "  colossus-legal branch: ${CURRENT_BRANCH}"
echo "  colossus-legal commit: $(git log --oneline -1)"

# Warn if there are uncommitted changes
if ! git diff --quiet HEAD 2>/dev/null; then
    echo "  ⚠ WARNING: Uncommitted changes in colossus-legal"
fi
echo ""

echo "============================================"
echo " Building Colossus-Legal ${VERSION}"
echo " Source: ${COLOSSUS_LEGAL_SRC}"
echo " Registry: ${REGISTRY}"
echo "============================================"
echo ""

# ── Build Backend ────────────────────────────────────────────
echo ""
echo "== Building backend (--no-cache) =="
podman build \
    --no-cache \
    -f "${COLOSSUS_LEGAL_SRC}/backend/Dockerfile" \
    -t "${BACKEND_IMAGE}:${VERSION}" \
    -t "${BACKEND_IMAGE}:latest" \
    "${COLOSSUS_LEGAL_SRC}/backend"
BACKEND_EXIT=$?

if [[ ${BACKEND_EXIT} -ne 0 ]]; then
    echo "ERROR: Backend build failed!"
    exit 1
fi
echo "  ✓ ${BACKEND_IMAGE}:${VERSION}"

# ── Build Frontend ───────────────────────────────────────────
# NOTE: No VITE_API_URL build arg needed!
# The API URL is injected at runtime via config.js (Ansible writes this).
echo ""
echo "== Building frontend (--no-cache) =="
podman build \
    --no-cache \
    -f "${COLOSSUS_LEGAL_SRC}/frontend/Dockerfile" \
    -t "${FRONTEND_IMAGE}:${VERSION}" \
    -t "${FRONTEND_IMAGE}:latest" \
    "${COLOSSUS_LEGAL_SRC}/frontend"
echo "  ✓ ${FRONTEND_IMAGE}:${VERSION}"

# ── Push to Registry ─────────────────────────────────────────
if [[ "${NO_PUSH}" == "--no-push" ]]; then
    echo ""
    echo "== Skipping push (--no-push) =="
else
    echo ""
    echo "== Pushing to ${REGISTRY} =="
    podman push "${BACKEND_IMAGE}:${VERSION}"
    podman push "${BACKEND_IMAGE}:latest"
    podman push "${FRONTEND_IMAGE}:${VERSION}"
    podman push "${FRONTEND_IMAGE}:latest"
    echo "  ✓ All images pushed"
fi

# ── Summary ──────────────────────────────────────────────────
echo ""
echo "============================================"
echo " Build complete: Colossus-Legal ${VERSION}"
echo ""
echo " Images:"
echo "   ${BACKEND_IMAGE}:${VERSION}"
echo "   ${FRONTEND_IMAGE}:${VERSION}"
echo ""
echo " Deploy via Semaphore:"
echo "   1. Run 'Deploy Colossus-Legal — DEV' → version: ${VERSION}"
echo "   2. Validate DEV"
echo "   3. Run 'Deploy Colossus-Legal — PROD' → version: ${VERSION}"
echo "============================================"
