#!/usr/bin/env bash
#
# create-build-vm-datasets.sh
#
# Provisions the ZFS datasets and Proxmox directory mappings that the
# colossus-build1 VM (VMID 230) consumes over virtiofs.
#
# RUN THIS ON pve-1 (as root), BEFORE creating VM 230 with create-vm.yml.
#
#   scp scripts/create-build-vm-datasets.sh root@10.10.100.3:/tmp/
#   ssh root@10.10.100.3 'bash /tmp/create-build-vm-datasets.sh'
#
# ─────────────────────────────────────────────────────────────────────────────
# IMPORTANT: virtiofs shares are NOT hot-pluggable.
#   The directory mappings MUST exist (and the datasets mounted) BEFORE the VM
#   boots. The VM has to be started with the virtiofs devices already present;
#   you cannot attach them to a running guest. If you create the VM before the
#   mappings exist, create-vm.yml's "Verify virtiofs directory mappings exist"
#   pre-flight will fail — which is the intended guard.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Proxmox node this VM lives on (matches the mapping's node= field).
NODE="pve-1"

# ── 1. ZFS datasets ──────────────────────────────────────────────────────────
# build-cache   — persistent build caches (cargo registry, rustup, npm, podman)
# build-scratch — disposable scratch space (target/, image build context)
# `zfs create` is NOT idempotent; ignore "dataset already exists".
for ds in build-cache build-scratch; do
  if zfs list "prod-zfs/${ds}" >/dev/null 2>&1; then
    echo "zfs dataset prod-zfs/${ds} already exists — skipping"
  else
    echo "creating zfs dataset prod-zfs/${ds}"
    zfs create "prod-zfs/${ds}"
  fi
done

# Datasets mount at /prod-zfs/<name> by default. World-traversable so the
# VM's unprivileged build user can reach them through virtiofs.
chmod 0755 /prod-zfs/build-cache /prod-zfs/build-scratch

# ── 2. Proxmox directory mappings (for virtiofs) ─────────────────────────────
# Mirrors the registration pattern used in playbooks/provision-vm-storage.yml:
#   pvesh create /cluster/mapping/dir --id <dirid> --map "node=<node>,path=<path>"
# The dirid here MUST match vm_virtiofs_shares[].dirid in vars/vm-230-build.yml
# (build-cache, build-scratch).
register_mapping() {
  local dirid="$1" path="$2"
  if pvesh get "/cluster/mapping/dir/${dirid}" >/dev/null 2>&1; then
    echo "dir mapping '${dirid}' already exists — skipping"
  else
    echo "creating dir mapping '${dirid}' -> ${path} on ${NODE}"
    pvesh create /cluster/mapping/dir \
      --id "${dirid}" \
      --map "node=${NODE},path=${path}"
  fi
}

register_mapping "build-cache"   "/prod-zfs/build-cache"
register_mapping "build-scratch" "/prod-zfs/build-scratch"

echo
echo "Done. Datasets + mappings ready. You can now run create-vm.yml for VM 230."
echo "(virtiofs is not hot-pluggable — the VM must boot with these present.)"
