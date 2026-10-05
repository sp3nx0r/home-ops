# Runbook: Restore Garage from Volsync/Kopia

## When to use

- Garage's metadata (`meta-garage-0`) or data (`data-garage-0`) volume is lost or corrupt, and Garage can't start or serve objects.
- You need to roll every bucket back to an earlier point in time.

Don't restore just because `garage block list-errors` shows a few blocks. With replication factor 1 a restore can't recover blocks that were already missing when the backup ran, and restoring only one of the two volumes loses data. On 2026-08-22 a data-only restore deleted about 53k blocks that the metadata still referenced.

## Why Garage needs its own procedure

Garage stores object metadata and data blocks on two separate volumes, and each is backed up hourly by its own `ReplicationSource` (`garage-meta` and `garage-data`). A restore must keep the two consistent:

- **Metadata must not be newer than data.** Newer metadata references blocks the data volume doesn't have. GETs for those objects then return `200` with an empty body, and Loki and Thanos fail with `unexpected EOF`.
- **Older metadata is safe.** Blocks it doesn't reference are garbage-collected by Garage. You lose writes made after the metadata snapshot.

Both backups start at the top of every hour, so a single run doesn't guarantee which volume was snapshotted first. Restore metadata from the run **one hour before** the data run.

The `ReplicationDestination`s for this are applied by hand from this runbook rather than kept in git. A standing destination that restores onto the live volumes overwrites Garage whenever someone changes its trigger.

## Prerequisites

- Successful recent runs of both `ReplicationSource`s:

    ```bash
    kubectl -n storage get replicationsource garage-data garage-meta
    ```

- Expect Loki, Thanos and Pocket ID to error against S3 while Garage is down.

## Procedure

### 1. Pick the restore times

Choose the data backup run you want, at hour `H`. Set `DATA_AS_OF` a few minutes after `H` so it selects that run, and `META_AS_OF` one hour earlier so it selects the `H-1` run:

```bash
DATA_AS_OF=2026-10-04T16:30:00Z
META_AS_OF=2026-10-04T15:30:00Z
TRIGGER=restore-$(date +%s)
```

To see exactly which snapshots exist, list them in Kopia as described in [the PVC restore runbook](runbook-restore-pvc.md#procedure-restore-a-specific-snapshot-not-latest). The identities are `garage-data@storage` and `garage-meta@storage`.

### 2. Stop Garage and keep Flux from restarting it

Suspend both the Kustomization and the HelmRelease. With only the Kustomization suspended, helm-controller still reconciles the StatefulSet back to one replica.

```bash
flux -n storage suspend ks garage
flux -n storage suspend hr garage
kubectl -n storage scale statefulset garage --replicas 0
kubectl -n storage wait pod garage-0 --for=delete --timeout=5m
```

### 3. Restore both volumes

Apply both destinations together. `copyMethod: Direct` writes straight into the live volumes, and `enableFileDeletion` makes each volume match its snapshot exactly.

```bash
for vol in meta data; do
  case $vol in meta) AS_OF=$META_AS_OF; CACHE=2Gi ;; data) AS_OF=$DATA_AS_OF; CACHE=5Gi ;; esac
  kubectl apply -f - <<EOF
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata:
  name: garage-$vol-restore
  namespace: storage
spec:
  trigger:
    manual: $TRIGGER
  kopia:
    destinationPVC: $vol-garage-0
    copyMethod: Direct
    enableFileDeletion: true
    restoreAsOf: "$AS_OF"
    cacheCapacity: $CACHE
    cacheStorageClassName: iscsi
    cacheAccessModes:
      - ReadWriteOnce
    cleanupCachePVC: true
    moverSecurityContext:
      runAsUser: 1000
      runAsGroup: 1000
      fsGroup: 1000
    moverVolumes:
      - mountPath: repository
        volumeSource:
          nfs:
            path: /mnt/tank/homelab/kopia
            server: 192.168.5.40
    repository: garage-volsync-secret
    sourceIdentity:
      sourceName: garage-$vol
EOF
done
```

Wait for both to finish. The data restore takes longest:

```bash
for vol in meta data; do
  kubectl -n storage wait replicationdestination garage-$vol-restore \
    --for=jsonpath='{.status.lastManualSync}'="$TRIGGER" --timeout=3h
done
kubectl -n storage get replicationdestination garage-meta-restore garage-data-restore \
  -o custom-columns=NAME:.metadata.name,RESULT:.status.latestMoverStatus.result,LAST:.status.lastSyncTime
```

Both results must be `Successful`. Then delete the destinations so nothing can rerun them:

```bash
kubectl -n storage delete replicationdestination garage-meta-restore garage-data-restore
```

### 4. Start Garage

```bash
flux -n storage resume hr garage
flux -n storage resume ks garage
kubectl -n storage rollout status statefulset garage --timeout=10m
```

### 5. Verify

```bash
kubectl -n storage exec garage-0 -- /garage status
kubectl -n storage exec garage-0 -- /garage repair --yes blocks
kubectl -n storage exec garage-0 -- /garage block list-errors
```

`repair blocks` re-checks every block the metadata references. After it finishes, `list-errors` should stay empty. Errors mean the metadata is newer than the data; redo the restore with an earlier `META_AS_OF`. `GarageBlockResyncErrors` also fires after an hour of errors.

Then confirm the S3 clients recovered: Loki and Thanos queries return data, and Pocket ID loads.

## Troubleshooting

| Symptom                                   | Cause                                                   | Fix                                                                             |
| ----------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------- |
| Mover pod stuck in `ContainerCreating`    | `garage-0` still holds the RWO volume                   | Check that the StatefulSet is at 0 replicas and both Flux objects are suspended |
| `garage-0` comes back while restoring     | HelmRelease wasn't suspended                            | Suspend it, scale to 0 again, and rerun step 3 with a new `TRIGGER`             |
| `list-errors` grows after `repair blocks` | Metadata snapshot newer than data snapshot              | Restore again with `META_AS_OF` one hour earlier                                |
| Restore picks an unexpected snapshot      | `restoreAsOf` selects the newest at or before that time | List snapshots in Kopia and adjust `DATA_AS_OF` / `META_AS_OF`                  |
