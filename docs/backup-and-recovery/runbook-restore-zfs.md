# Runbook: ZFS snapshot rollback

## When to use

- Quick local recovery of files deleted or corrupted within the snapshot retention window
- NFS dataset: within 24 hours (hourly snapshots) or 14 days (daily snapshots for k8s-exports)
- iSCSI dataset: within 24 hours (hourly snapshots)
- No need to go to B2 — faster RTO (seconds vs hours)

## Snapshot retention summary

| Dataset | Schedule | Retention |
|---------|----------|-----------|
| `tank/backups` | Hourly | 24h |
| `tank/homelab/k8s-exports` | Hourly | 24h |
| `tank/homelab/k8s-exports` | Daily (2am) | 14d |
| `tank/homelab/k8s-iscsi` | Hourly | 24h |
| `tank/media` | Daily (3am) | 7d |

## Procedure: Restore files from an NFS dataset snapshot

ZFS snapshots are accessible via the `.zfs/snapshot` hidden directory on any mounted dataset.

### 1. List available snapshots

```bash
ssh nas 'zfs list -t snapshot -r tank/homelab/k8s-exports -o name,creation -s creation'
```

### 2. Browse a snapshot

```bash
# Snapshots are read-only and accessible at:
ssh nas 'ls /mnt/tank/homelab/k8s-exports/.zfs/snapshot/'

# Browse a specific snapshot
ssh nas 'ls -la /mnt/tank/homelab/k8s-exports/.zfs/snapshot/hourly-2026-05-01_08:00/'
```

### 3. Restore specific files

```bash
# Copy a file from a snapshot back to the live dataset
ssh nas 'cp /mnt/tank/homelab/k8s-exports/.zfs/snapshot/hourly-2026-05-01_08:00/path/to/file \
            /mnt/tank/homelab/k8s-exports/path/to/file'

# Restore an entire directory
ssh nas 'cp -a /mnt/tank/homelab/k8s-exports/.zfs/snapshot/hourly-2026-05-01_08:00/some-app/ \
              /mnt/tank/homelab/k8s-exports/some-app/'
```

### 4. Clone a snapshot for safe browsing (optional)

If you need to browse a snapshot interactively without risk of overwriting live data:

```bash
# Clone the snapshot to a temporary dataset
ssh nas 'zfs clone tank/homelab/k8s-exports@hourly-2026-05-01_08:00 tank/scratch/restore-temp'

# Browse at /mnt/tank/scratch/restore-temp
ssh nas 'ls -la /mnt/tank/scratch/restore-temp/'

# When done, destroy the clone
ssh nas 'zfs destroy tank/scratch/restore-temp'
```

## Procedure: Restore an iSCSI zvol snapshot

iSCSI zvol snapshots are block-level and require more care since the zvol may be actively attached to a Kubernetes node.

### 1. List available zvol snapshots

```bash
ssh nas 'zfs list -t snapshot -r tank/homelab/k8s-iscsi -o name,creation -s creation'
```

### 2. Detach the zvol from Kubernetes

```bash
# Scale down the app using the PVC
kubectl -n <namespace> scale deploy/<app-name> --replicas 0

# Wait for pod termination
kubectl -n <namespace> wait pod \
  --for=delete \
  --selector="app.kubernetes.io/name=<app-name>" \
  --timeout=2m

# Detach the PV from the node (democratic-csi should handle this)
# Verify no iSCSI sessions are using the zvol:
ssh nas 'midclt call iscsi.target.query' | jq '.[] | select(.name | contains("<pvc-name>"))'
```

### 3. Rollback the zvol

> **WARNING**: `zfs rollback` destroys all data written after the snapshot. This is irreversible.

```bash
# Rollback to a specific snapshot
ssh nas 'zfs rollback tank/homelab/k8s-iscsi/<zvol-name>@hourly-2026-05-01_08:00'
```

### 4. Reattach and verify

```bash
# Scale the app back up
kubectl -n <namespace> scale deploy/<app-name> --replicas 1

# Verify the app is healthy
kubectl -n <namespace> get pods -w
```

## Procedure: Rollback an entire NFS dataset

> **WARNING**: Full dataset rollback destroys all changes across all files since the snapshot. Only use when you need to revert everything.

```bash
# Stop all workloads using the dataset first
# Then rollback
ssh nas 'zfs rollback -r tank/homelab/k8s-exports@hourly-2026-05-01_08:00'
```

Prefer file-level restores (copying from `.zfs/snapshot/`) over full dataset rollbacks whenever possible.

## TODO

- [ ] Test iSCSI zvol snapshot rollback end-to-end with democratic-csi
- [ ] Document how to identify which zvol belongs to which PVC (`kubectl get pv -o wide`)
- [ ] Test democratic-csi VolumeSnapshot restore as an alternative to manual rollback
