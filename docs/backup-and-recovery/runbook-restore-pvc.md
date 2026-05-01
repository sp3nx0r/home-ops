# Runbook: Restore a Kubernetes PVC (Volsync/Kopia)

## When to use

- App data corruption (bad migration, buggy release, user error)
- Need to roll back a PVC to a previous Kopia snapshot
- Recovering an app that was deleted and needs its data back

## Prerequisites

- Volsync controller running in `volsync-system`
- App has a `ReplicationSource` and `ReplicationDestination` configured (via the volsync Kustomize component)
- At least one successful Kopia snapshot exists for the app
- `kubectl` access to the cluster

## Verify snapshots exist

```bash
# Check last successful sync
kubectl -n <namespace> get replicationsource <app-name>

# Browse snapshots via Kopia server UI (if deployed)
# Or check directly on NAS:
ssh nas 'ls -la /mnt/tank/homelab/kopia/'
```

## Procedure: Restore latest snapshot

### 1. Suspend the app

```bash
# Suspend Flux reconciliation so it doesn't fight the restore
flux -n <namespace> suspend ks <app-name>

# Scale down the app to release the PVC
kubectl -n <namespace> scale deploy/<app-name> --replicas 0

# Wait for pod to terminate
kubectl -n <namespace> wait pod \
  --for=delete \
  --selector="app.kubernetes.io/name=<app-name>" \
  --timeout=2m
```

### 2. Trigger the restore

The `ReplicationDestination` created by the volsync component has `trigger.manual: restore-once`. Patch it with a new value to trigger a restore:

```bash
kubectl -n <namespace> patch replicationdestination <app-name>-dst \
  --type merge \
  -p "{\"spec\":{\"trigger\":{\"manual\":\"restore-$(date +%s)\"}}}"
```

### 3. Monitor progress

```bash
# Watch the ReplicationDestination status
kubectl -n <namespace> get replicationdestination <app-name>-dst -w

# Check for mover pod
kubectl -n <namespace> get pods -l volsync.backube/component

# View mover logs
kubectl -n <namespace> logs -l volsync.backube/component -f
```

The restore creates a new PVC from the Kopia snapshot. The `ReplicationDestination` has `cleanupCachePVC: true` and `cleanupTempPVC: true`, so temporary resources are cleaned up automatically.

### 4. Resume the app

```bash
flux -n <namespace> resume ks <app-name>
flux -n <namespace> reconcile ks <app-name> --force

# Verify the app comes up with restored data
kubectl -n <namespace> get pods -w
```

### 5. Verify data integrity

Check the app's logs and UI to confirm data was restored correctly. The specifics depend on the app.

## Procedure: Restore a specific snapshot (not latest)

The default `ReplicationDestination` restores the latest snapshot. To restore a specific point in time, you need to specify the Kopia snapshot ID.

```bash
# List available snapshots for the app's identity
# (identity = <app-name>@<namespace> by default)
ssh nas

# Connect to the kopia repo
export KOPIA_PASSWORD='<from volsync-maintenance-secret>'
kopia repository connect filesystem --path /mnt/tank/homelab/kopia

# List snapshots for the app
kopia snapshot list --all

# Note the snapshot ID for your desired point in time
# Then disconnect
kopia repository disconnect
exit
```

To restore a specific snapshot, add `previous` to the ReplicationDestination spec before triggering. This requires editing the volsync component or creating a one-off ReplicationDestination manifest.

> **TODO**: Document the exact `previous` field usage and test with a specific snapshot ID.

## Procedure: Cross-namespace restore

If restoring data into a different namespace than the original:

```yaml
spec:
  kopia:
    sourceIdentity:
      sourceName: <original-replicationsource-name>
      sourceNamespace: <original-namespace>
```

Add this to the `ReplicationDestination` spec so Volsync can find the correct Kopia snapshot identity.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `secret should have fields: [KOPIA_REPOSITORY KOPIA_PASSWORD]` | Missing or malformed volsync secret | Check `<app>-volsync-secret` has both fields |
| Mover pod stuck in `ContainerCreating` | PVC still attached to running app pod | Scale down the app first |
| `No repository configuration found` | `KOPIA_REPOSITORY` format wrong | Must be `filesystem:///mnt/repository` |
| Restore completes but PVC is empty | Wrong snapshot identity | Check `sourceIdentity` or list snapshots in Kopia |
| `Directory is empty skipping backup` | Source PVC had no data when snapshotted | Check that the app wrote data before the last backup ran |

## TODO

- [ ] Test full suspend → restore → resume cycle with `volsync-test`
- [ ] Document `previous` field for point-in-time restores
- [ ] Document cross-namespace restore with `sourceIdentity`
- [ ] Add Taskfile commands for common restore operations
