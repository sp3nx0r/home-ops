# Backup Strategy

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────┐
│                   Kubernetes Cluster (Talos)                  │
│                                                               │
│  PVCs (NFS) ──────────► tank/homelab/k8s-exports              │
│  PVCs (iSCSI) ────────► tank/homelab/k8s-iscsi (zvols)        │
│  VolumeSnapshots ─────► tank/homelab/k8s-iscsi-snaps          │
│                                                               │
│  Volsync (perfectra1n fork v0.18.5)                           │
│    ReplicationSource ──► snapshot iSCSI PVC ──► Kopia backup  │
│    Kopia repo (NFS) ──► tank/homelab/kopia                    │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────┐
│                 TrueNAS SCALE (themberchaud)                  │
│                                                               │
│  Pool: tank (5x4TB RAIDZ1)                                    │
│                                                               │
│  ZFS Periodic Snapshots:                                      │
│    tank/backups             → hourly, retain 24h              │
│    tank/homelab/k8s-exports → hourly, retain 24h              │
│    tank/homelab/k8s-exports → daily, retain 14d               │
│    tank/homelab/k8s-iscsi   → hourly, retain 24h (recursive)  │
│    tank/media               → daily, retain 7d                │
│                                                               │
│  Kopia Repository: tank/homelab/kopia (NFS-shared)            │
│    Deduplication-aware backup target for Volsync              │
│    Kopia server UI via kopia.securimancy.com                  │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼ (nightly, staggered)
┌───────────────────────────────────────────────────────────────┐
│                    Backblaze B2 (offsite)                     │
│                                                               │
│  Bucket: sp3nx0r-truenas (rclone crypt, versioned)            │
│  Cloud Sync: per-dataset PUSH (snapshot: true)                │
│  Transfer mode: SYNC                                          │
│  Schedule: staggered nightly (00:00–00:30)                    │
│  Versioning: enabled, 30-day noncurrent retention             │
│  Includes tank/homelab/kopia → offsite Kopia repo copy        │
│  Config: ansible/playbooks/backblaze-configure.yml            │
│                                                               │
│  TrueNAS Config Backup:                                       │
│    Cron: daily 23:45 → /mnt/tank/backups/truenas-config/      │
│    freenas-v1.db + pwenc_secret, 14-day retention             │
│    Synced offsite via B2 - backups cloud sync task            │
└───────────────────────────────────────────────────────────────┘
```

## Protection Levels

### Level 1: ZFS RAIDZ1 (hardware failure)

- **What it protects against**: Single disk failure
- **RPO**: 0 (no data loss for single disk failure)
- **RTO**: Minutes (automatic rebuild)
- **Coverage**: All data on `tank`

### Level 2: ZFS Periodic Snapshots (accidental deletion / corruption)

- **What it protects against**: Accidental file deletion, application bugs, ransomware
- **RPO**:
  - `tank/backups`: 1 hour (retained 24h)
  - `tank/homelab/k8s-exports`: 1 hour (retained 24h) + daily (retained 14d)
  - `tank/homelab/k8s-iscsi`: 1 hour (retained 24h, recursive across all zvols)
  - `tank/media`: 1 day (retained 7d)
- **RTO**: Seconds (ZFS rollback or clone)
- **Coverage**: NFS-backed Kubernetes PVCs, iSCSI zvols, backups, media

### Level 3: Volsync + Kopia (iSCSI PVC application-level backup)

- **What it protects against**: Data loss in iSCSI PVCs, bad deployments, application corruption, accidental deletion
- **RPO**: 1 hour (hourly schedule, configurable per-app)
- **RTO**: Minutes (restore PVC from Kopia snapshot via ReplicationDestination)
- **Coverage**: Any iSCSI-backed PVC with a Volsync ReplicationSource configured
- **Retention**: 24 hourly + 7 daily snapshots (configurable per-app)
- **Deduplication**: Kopia content-defined chunking with zstd-fastest compression across all PVCs sharing the repository
- **How it works**:
  1. Volsync creates a VolumeSnapshot of the source iSCSI PVC (via democratic-csi)
  2. A temporary PVC is provisioned from the snapshot
  3. A Kopia mover pod mounts the temporary PVC + NFS repository and runs `kopia snapshot create`
  4. Temporary PVC and snapshot are cleaned up
  5. Restore uses `ReplicationDestination` to pull data from Kopia back into a new PVC

#### Components

| Component | Namespace | Purpose |
|-----------|-----------|---------|
| Volsync controller (perfectra1n fork 0.18.5) | `volsync-system` | Orchestrates ReplicationSource/Destination lifecycle, CRDs include `kopia` mover |
| Kopia server | `volsync-system` | Web UI for repository browsing/management, connects to NFS repo |
| Kopia repository | NFS `192.168.5.40:/mnt/tank/homelab/kopia` | Shared filesystem-based Kopia repository, deduplicates across all backup sources |
| Volsync component | `kubernetes/components/volsync/` | Reusable Kustomize component providing ReplicationSource + ReplicationDestination templates |
| Per-app secret | `${APP}-volsync-secret` | Contains `KOPIA_PASSWORD` and `KOPIA_REPOSITORY` (format: `filesystem:///mnt/repository`) |

#### Adding Volsync to a new app

1. Add the volsync Kustomize component to the app's `kustomization.yaml`:
   ```yaml
   components:
     - ../../../../components/volsync
   ```
2. Create a SOPS-encrypted secret named `${APP}-volsync-secret` with `KOPIA_PASSWORD` and `KOPIA_REPOSITORY: filesystem:///mnt/repository`
3. Set `postBuild.substitute` in the app's Flux Kustomization:
   ```yaml
   postBuild:
     substitute:
       APP: my-app
       VOLSYNC_CAPACITY: 5Gi
       VOLSYNC_UID: "1000"
       VOLSYNC_GID: "1000"
   ```
4. The PVC must be named `${APP}` to match the ReplicationSource's `sourcePVC` reference

### Level 4: Kubernetes VolumeSnapshots (iSCSI point-in-time recovery)

- **What it protects against**: Bad deployments, data migration failures, pre-upgrade safety nets
- **RPO**: On-demand (manual trigger or scheduled via Volsync)
- **RTO**: Minutes (restore PVC from snapshot)
- **Coverage**: iSCSI-backed PVCs (democratic-csi)
- **Storage**: Detached snapshots in `tank/homelab/k8s-iscsi-snaps`
- **Note**: Volsync creates VolumeSnapshots as part of its backup flow; they are transient (cleaned up after the Kopia mover completes)

### Level 5: Backblaze B2 Cloud Sync (disaster recovery)

- **What it protects against**: Total NAS loss (fire, theft, multiple disk failure, controller failure)
- **RPO**: 24 hours (nightly sync, staggered 00:00–00:30)
- **RTO**: Hours to days (depending on bandwidth for full restore)
- **Coverage**: Per-dataset cloud sync tasks with ZFS snapshot consistency:
  | Task | Path | Schedule | Snapshot |
  |------|------|----------|----------|
  | B2 - backups | `/mnt/tank/backups` | 00:00 | Yes |
  | B2 - k8s-exports | `/mnt/tank/homelab/k8s-exports` | 00:00 | Yes |
  | B2 - kopia | `/mnt/tank/homelab/kopia` | 00:15 | Yes |
  | B2 - media | `/mnt/tank/media` | 00:30 | Yes |
- **Transfer mode**: SYNC (mirror, deletes removed files from B2)
- **Versioning**: Enabled — noncurrent versions retained 30 days, protecting against accidental/malicious deletion propagation
- **Encryption**: Server-side encryption enabled on bucket; rclone crypt layer on all sync tasks
- **Config as code**: Bucket settings managed by `ansible/playbooks/backblaze-configure.yml`; cloud sync tasks codified in `ansible/playbooks/truenas-configure.yml`

### Level 6: TrueNAS Config Backup (system recovery)

- **What it protects against**: NAS OS reinstall, configuration loss, corrupted system DB
- **RPO**: 24 hours (daily cron at 23:45)
- **RTO**: Minutes (restore DB + secret seed during TrueNAS install)
- **Coverage**: Full TrueNAS configuration database (`freenas-v1.db`) + password encryption seed (`pwenc_secret`)
- **Retention**: 14 daily copies on-disk, plus B2 versioning for 30 additional days
- **Storage**: `/mnt/tank/backups/truenas-config/` (synced offsite by the "B2 - backups" cloud sync task)

## What's NOT Covered

| Gap | Risk | Mitigation |
|-----|------|------------|
| Not all iSCSI PVCs have Volsync configured | Apps without a ReplicationSource have no application-level backup | Add Volsync component to all stateful apps |
| RAIDZ1 can only tolerate 1 disk failure | Second disk failure during rebuild = total pool loss | Phase 2 migration to 2x RAIDZ2 (planned) |
| No application-consistent snapshots | Database crash-consistency not guaranteed for iSCSI zvol snapshots | Use app-level backup tools (pg_dump, etc.) before snapshots |
| Kopia repo is single-site (NFS on TrueNAS) | NAS loss = Kopia repo loss (until B2 sync restores it) | Kopia repo is included in B2 nightly sync via `/mnt/tank` |
| Kubernetes etcd/cluster state not backed up | Cluster rebuild requires full re-bootstrap | GitOps (Flux) reconstructs cluster state from git |

## Key Weaknesses

1. **RAIDZ1 is fragile during rebuilds** — with 5 disks in RAIDZ1, a second failure during a rebuild (which can take hours on large disks) means total data loss. The Phase 2 migration to dual RAIDZ2 vdevs addresses this.

2. **Cloud sync does not capture iSCSI zvol data directly** — zvols are block devices under `/dev/zvol/`, not files under `/mnt/`. The Backblaze task syncs `/mnt/tank` which includes dataset files but not raw zvol block data. **Partially mitigated**: Volsync + Kopia stores iSCSI PVC data as deduplicated file content in the Kopia NFS repo (`tank/homelab/kopia`), which *is* included in the B2 sync. Apps with Volsync configured have offsite coverage through this path.

## Recommendations

| Priority | Action |
|----------|--------|
| High | Add Volsync ReplicationSource to all stateful iSCSI-backed apps (currently only `volsync-test` is configured) |
| Medium | Document and test restore procedures (see `docs/backup-and-recovery/`) |
| Low | Consider app-level backup CronJobs for databases (pg_dump, etc.) before snapshots |
| Low | Remove `volsync-test` app once real workloads are backed up by Volsync |
