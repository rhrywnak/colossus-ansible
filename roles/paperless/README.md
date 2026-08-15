# roles/paperless

Deploys Paperless-ngx to VM-130 (`docs1`) as four Quadlet containers on a
Quadlet `.network`. Writes units and the environment file; the playbook
enables and starts them.

- **Spec:** `COLOSSUS_PAPERLESS_INFRASTRUCTURE_SPEC_v1.md`
- **Tracker:** `COLOSSUS_PAPERLESS_EXECUTION_TASK_TRACKER_v2.md`
- **Butane:** `colossus-homelab/butane/docs1.bu` — VM, NFS mounts, Python. Not the units.

## Why the units are here and not in Butane

1. `PAPERLESS_SECRET_KEY` comes from Ansible Vault. A Quadlet baked into
   Ignition would reference an `EnvironmentFile` that does not exist until
   Ansible has run, so the container would crash-loop on first boot.
2. Re-pinning any of four image digests would otherwise mean a full VM
   rebuild instead of a playbook run.
3. The role path is the only container-deployment pattern proven on this fleet
   (`roles/colossus-legal/`).

## The two things most likely to be got wrong

### 1. Container identity — non-root, `User=3002` / `Group=3001`

**Do not switch to root mode with `USERMAP_UID`/`USERMAP_GID`.** They still
work in 3.0.5, but in root mode the image's `init-folders` step runs:

```bash
find <dir> -not \( -user paperless -and -group paperless \) \
     -exec chown paperless:paperless {} +
```

over `consume/`. The NFS client is squashed to 3001 and therefore **owns**
those files, and ZFS/NFSv4 grants `owner@` the `WRITE_OWNER` bit — so the chown
**succeeds**. The consume directory then belongs to 3002 while the client is
squashed to 3001; `group@` is not honoured for squashed clients, and VM-130
loses all access to its own intake folder:

```
ls: cannot open directory '/var/mnt/usershare/paperless-consume/': Permission denied
```

It cannot be undone from the client — it is no longer the owner. Repair needs
`midclt call filesystem.chown` on TrueNAS.

Root mode does not crash. It succeeds, logs nothing wrong, keeps serving HTTP
200, and bricks its own intake folder. Non-root has no chown branch at all — it
only warns, and **those warnings in the journal are expected and correct.**

Why `3002:3001` and not something else: `mapall` squashes every client
credential, so the container uid is irrelevant on *both* NFS mounts. It only
has to satisfy the **local** data dir, which Butane creates `3002:3001` mode
`0770`.

### 2. `/mnt` vs `/var/mnt`

- `Volume=` lines use **`/mnt/...`** (the symlink)
- `RequiresMountsFor=` uses **`/var/mnt/...`** (the canonical path)

Quadlet auto-generates a `RequiresMountsFor=` from each `Volume=` host path *as
written*. systemd does not resolve symlinks for mount-unit names, so those
auto-generated entries match nothing and are silently a no-op. The hand-written
`RequiresMountsFor=` in `paperless-app.container` `[Unit]` is what actually
holds the start until the NFS mounts are up.

## Other constraints that are not stylistic

| | |
|---|---|
| `:Z` on the local data volume **only** | NFS has no xattr support; a relabel fails as it does on virtiofs. The NFS mounts already carry `context=` from `docs1.bu` |
| Both Gotenberg flags, verbatim | The default deny-list covers only `file:` — the **allow-list** is what stops a tracking pixel in opposing counsel's email reaching the network |
| `PAPERLESS_CONSUMER_POLLING_INTERVAL` | The shorter `PAPERLESS_CONSUMER_POLLING` does not exist in 3.0.5. Setting it is accepted silently and leaves inotify active, which is unreliable over NFS |
| `PAPERLESS_ALLOWED_HOSTS` set explicitly | `PAPERLESS_URL` only *appends*; `ALLOWED_HOSTS` defaults to `['*']` and would reject nothing |
| `PAPERLESS_OCR_LANGUAGE` singular | The plural runs `apt-get install` at every container start |
| `PAPERLESS_AI_ENABLED=NO` explicit | Off by default in 3.0.5, but a privileged corpus should not depend on an upstream default holding across versions |
| Only 8000 published | 6379 / 9998 / 3000 stay on the container network |

## Storage split (spec §5.1, non-negotiable)

| Path | Location | Contents |
|---|---|---|
| `/var/lib/paperless/data` | **local `/dev/sda4`** | SQLite, tantivy index, `llm_index/`, classifier |
| `/mnt/paperless/media` | NFS export 14 | originals, archive copies, thumbnails, sharelink bundles |
| `/mnt/paperless/export` | NFS export 14 | `document_exporter` output |
| `/mnt/usershare/paperless-consume` | NFS export 13 | watched intake folder |

SQLite file locking over NFS corrupts. `data/` never moves to a network mount.

## Hardening posture

`NoNewPrivileges=true` on all four now. `DropCapability=` is deliberately
**staged**, not omitted by oversight:

- **broker** — the valkey entrypoint starts as root and drops to the `valkey` user, which needs `SETUID`/`SETGID`.
- **gotenberg** — Chromium sandboxing interacts with `no-new-privileges`; tightening blind risks breaking the exact conversion path the hardening flags exist to protect.

Tighten per container **after** P-43 proves `.eml` and Office ingest, then
re-run P-45.

## Local render for Quadlet validation

Writes the real bytes without touching docs1 — see the header of
`playbooks/deploy-paperless.yml`. **`rm -rf /tmp/qrender-env` immediately
afterwards**; it holds the real secret key in plaintext.

## Secret handling

`PAPERLESS_SECRET_KEY` lives in `inventory/group_vars/all/vault.yml` as
`vault_paperless_secret_key`. The task that writes the env file carries
`no_log: true` and the file is `0600`.

- **Never** run this playbook with `-vvv` — Semaphore persists task logs.
- **Never** run bare `podman inspect paperless-app` — `--env-file` values are
  materialized into the container config and it prints the key in full. Always
  `--format` a specific field.
- `journalctl -u paperless-app` is safe: `ExecStart` shows the env-file *path*.
