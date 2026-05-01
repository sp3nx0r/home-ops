# Backup & Recovery

Documentation for the homelab backup architecture and recovery procedures.

## Documents

| Document | Description |
|----------|-------------|
| [Backup Strategy](backup-strategy.md) | Architecture overview, protection levels, gaps, and recommendations |
| [Runbook: Restore files from Backblaze B2](runbook-restore-b2.md) | Recover files deleted or overwritten within the 30-day versioning window |
| [Runbook: Full NAS disaster recovery](runbook-disaster-recovery.md) | Rebuild from scratch after total NAS loss |
| [Runbook: Restore a Kubernetes PVC (Volsync)](runbook-restore-pvc.md) | Roll back app data from Kopia snapshots |
| [Runbook: ZFS snapshot rollback](runbook-restore-zfs.md) | Quick local recovery from periodic ZFS snapshots |
