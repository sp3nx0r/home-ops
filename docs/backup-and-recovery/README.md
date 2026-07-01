# Backup & Recovery

Documentation for the homelab backup architecture and recovery procedures.

## Current Offsite Structure

Backblaze B2 is split by retention policy. TrueNAS Cloud Sync tasks are managed
by Ansible and enabled for nightly PUSH syncs.

| Local source | B2 bucket | Remote path | Noncurrent retention |
|--------------|-----------|-------------|----------------------|
| `tank/backups/workstations` | `sp3nx0r-backups-workstation` | `workstations/` | 3 days |
| `tank/backups/git-bundles` | `sp3nx0r-backups-workstation` | `git-bundles/` | 3 days |
| `tank/backups/archive` | `sp3nx0r-backups-archive` | bucket root | 90 days |
| `tank/backups/truenas-config` | `sp3nx0r-backups-truenas-config` | bucket root | 90 days |
| `tank/homelab/k8s-exports` | `sp3nx0r-homelab` | `k8s-exports/` | 30 days |
| `tank/homelab/kopia` | `sp3nx0r-homelab-kopia` | bucket root | 1 day; Kopia owns backup retention |
| `tank/media` | `sp3nx0r-media` | bucket root | 1 day |

The retired `sp3nx0r-truenas` bucket is no longer part of the architecture.

## Documents

| Document | Description |
|----------|-------------|
| [Backup Strategy](backup-strategy.md) | Architecture overview, protection levels, gaps, and recommendations |
| [Runbook: Restore files from Backblaze B2](runbook-restore-b2.md) | Recover files deleted or overwritten within the bucket-specific versioning window |
| [Runbook: Full NAS disaster recovery](runbook-disaster-recovery.md) | Rebuild from scratch after total NAS loss |
| [Runbook: Restore a Kubernetes PVC (Volsync)](runbook-restore-pvc.md) | Roll back app data from Kopia snapshots |
| [Runbook: ZFS snapshot rollback](runbook-restore-zfs.md) | Quick local recovery from periodic ZFS snapshots |
