# Backup Strategy

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster (Talos)                    │
│                                                                   │
│  PVCs (NFS) ──────────► tank/homelab/k8s-exports                 │
│  PVCs (iSCSI) ────────► tank/homelab/k8s-iscsi (zvols)           │
│  VolumeSnapshots ─────► tank/homelab/k8s-iscsi-snaps             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                  TrueNAS SCALE (themberchaud)                     │
│                                                                   │
│  Pool: tank (5x4TB RAIDZ1)                                       │
│                                                                   │
│  ZFS Periodic Snapshots:                                          │
│    tank/backups             → hourly, retain 24h                  │
│    tank/homelab/k8s-exports → hourly, retain 24h                  │
│    tank/homelab/k8s-exports → daily, retain 14d                   │
│    tank/media               → daily, retain 7d                    │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ (nightly at midnight)
┌─────────────────────────────────────────────────────────────────┐
│                     Backblaze B2 (offsite)                        │
│                                                                   │
│  Cloud Sync: PUSH entire /mnt/tank                               │
│  Transfer mode: SYNC                                              │
│  Schedule: daily at 00:00                                         │
└─────────────────────────────────────────────────────────────────┘
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
  - `tank/media`: 1 day (retained 7d)
- **RTO**: Seconds (ZFS rollback or clone)
- **Coverage**: NFS-backed Kubernetes PVCs, backups, media

### Level 3: Kubernetes VolumeSnapshots (iSCSI point-in-time recovery)

- **What it protects against**: Bad deployments, data migration failures, pre-upgrade safety nets
- **RPO**: On-demand (manual trigger or scheduled via controllers)
- **RTO**: Minutes (restore PVC from snapshot)
- **Coverage**: iSCSI-backed PVCs (democratic-csi)
- **Storage**: Detached snapshots in `tank/homelab/k8s-iscsi-snaps`

### Level 4: Backblaze B2 Cloud Sync (disaster recovery)

- **What it protects against**: Total NAS loss (fire, theft, multiple disk failure, controller failure)
- **RPO**: 24 hours (nightly sync at midnight)
- **RTO**: Hours to days (depending on bandwidth for full restore)
- **Coverage**: Entire `tank` pool
- **Transfer mode**: SYNC (mirror, deletes removed files from B2)

## What's NOT Covered

| Gap | Risk | Mitigation |
|-----|------|------------|
| iSCSI zvols have no periodic ZFS snapshots | Corruption or deletion between Backblaze runs = up to 24h data loss | Add hourly snapshot task for `tank/homelab/k8s-iscsi` |
| RAIDZ1 can only tolerate 1 disk failure | Second disk failure during rebuild = total pool loss | Phase 2 migration to 2x RAIDZ2 (planned) |
| Backblaze sync mode is SYNC (not COPY) | Ransomware/accidental bulk delete propagates to B2 on next sync | Enable B2 bucket versioning or lifecycle rules for retention |
| No application-consistent snapshots | Database crash-consistency not guaranteed for iSCSI zvol snapshots | Use app-level backup tools (pg_dump, etc.) before snapshots |
| Cloud sync runs without ZFS snapshot | Files may be in inconsistent state during the sync window | Enable `snapshot: true` on the cloud sync task |
| No off-site replication of iSCSI zvols specifically | iSCSI data only reaches B2 via the `/mnt/tank` sync (zvols are block devices, not files) | Verify B2 sync includes `/dev/zvol` or zvol raw data |
| Kubernetes etcd/cluster state not backed up | Cluster rebuild requires full re-bootstrap | GitOps (Flux) reconstructs cluster state from git |

## Key Weaknesses

1. **iSCSI zvols are not periodically snapshotted** — unlike `k8s-exports`, there's no hourly snapshot task for `tank/homelab/k8s-iscsi`. A zvol corruption has no local rollback point.

2. **RAIDZ1 is fragile during rebuilds** — with 5 disks in RAIDZ1, a second failure during a rebuild (which can take hours on large disks) means total data loss. The Phase 2 migration to dual RAIDZ2 vdevs addresses this.

3. **SYNC mode propagates deletions to B2** — if data is accidentally or maliciously deleted on TrueNAS, the next nightly sync removes it from B2 too. B2 bucket versioning with a retention policy (e.g., keep deleted files for 30 days) would close this gap.

4. **Cloud sync may not capture iSCSI zvol data** — zvols are block devices under `/dev/zvol/`, not files under `/mnt/`. The Backblaze task syncs `/mnt/tank` which includes dataset files but likely not raw zvol block data. Verify this.

5. **No snapshot consistency for cloud sync** — the cloud sync task has `snapshot: false`, meaning files could be mid-write during the sync window, resulting in potentially corrupt backups for actively-written files.

## Recommendations

| Priority | Action |
|----------|--------|
| High | Add hourly ZFS snapshot task for `tank/homelab/k8s-iscsi` (recursive, retain 24h) |
| High | Verify whether Backblaze cloud sync captures iSCSI zvol data; if not, add a separate task or use ZFS send/receive to a file-based dataset |
| High | Enable B2 bucket versioning with 30-day lifecycle retention |
| Medium | Enable `snapshot: true` on the Backblaze cloud sync task for crash-consistent offsite backups |
| Medium | Add Volsync or scheduled VolumeSnapshots for critical iSCSI PVCs |
| Low | Consider app-level backup CronJobs for databases (pg_dump, etc.) |
