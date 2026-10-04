# Runbook: Grow a StatefulSet PVC

## When to use

A PVC created from a StatefulSet's `volumeClaimTemplates` is running out of space (for example `GarageDataVolumePredictedToFill` or `KubePersistentVolumeFillingUp`), and the size is set in a HelmRelease.

StatefulSets in the cluster with `volumeClaimTemplates`:

| Namespace | StatefulSet                               | Templates                                                           |
| --------- | ----------------------------------------- | ------------------------------------------------------------------- |
| `storage` | `garage`                                  | `meta`, `data`                                                      |
| `o11y`    | `loki`                                    | `storage`                                                           |
| `o11y`    | `thanos-compactor`, `thanos-storegateway` | `data`                                                              |
| `o11y`    | `prometheus-kube-prometheus-stack`        | `prometheus-kube-prometheus-stack-db` (operator-managed, see below) |

## Why it needs a procedure

`volumeClaimTemplates` are immutable. Merging only the new size makes the Helm upgrade fail with `Forbidden: updates to statefulset spec`. Flux retries, then rolls back, and the HelmRelease ends up failed. Nothing is lost, but nothing grows either.

The `iscsi` StorageClass has `allowVolumeExpansion: true`, and democratic-csi zvols are thin-provisioned, so a bigger request reserves no pool space up front.

## Before you start

1. Check pool headroom: `ssh nas 'zfs list -o name,used,avail tank'`.
2. Remember that every byte on a Volsync-backed PVC also grows the Kopia repo and the B2 bucket.
3. List the chart's hooks (`helm get hooks -n <ns> <release>`). If a `post-upgrade` hook calls another service, make sure the CNPs allow that traffic. A hook that hangs on a missing CNP rule times out, the upgrade rolls back, and the old template comes back.

## Procedure

Run steps 1 and 2 **before** merging the size change.

### 1. Expand the live PVC

```bash
kubectl -n <ns> patch pvc <pvc-name> -p '{"spec":{"resources":{"requests":{"storage":"<new-size>"}}}}'
kubectl -n <ns> get pvc <pvc-name> -w
```

Wait until `CAPACITY` shows the new size. The online ext4 resize clears the `FileSystemResizePending` condition once it finishes.

### 2. Delete the StatefulSet, keeping its pods and PVCs

```bash
kubectl -n <ns> delete sts <sts-name> --cascade=orphan
```

The pods keep running and serving. Drift detection is off, so Flux won't recreate the StatefulSet until the next reconcile.

### 3. Merge the size change and reconcile

The commit raises the size in the HelmRelease. Also update anything that has to match it:

- The Volsync `ReplicationDestination` capacity: `VOLSYNC_CAPACITY` in `ks.yaml` for the volsync component, or the explicit `capacity` (Garage defines its own in `app/volsync.yaml`).
- Any value the chart derives from the size. For Garage, the layout capacity defaults to `persistence.data.size`.

```bash
flux reconcile ks <app> -n <ns> --with-source
```

The StatefulSet is recreated with the new template, adopts the existing PVCs, and rolls each pod once.

### 4. Verify

```bash
kubectl -n <ns> get sts <sts-name> -o jsonpath='{.spec.volumeClaimTemplates[*].spec.resources.requests.storage}'
flux get hr -n <ns> <release>
kubectl -n <ns> get pvc <pvc-name>
```

The HelmRelease is Ready, any hook Jobs succeeded, and the fill alert has cleared. For Garage, `kubectl -n storage exec garage-0 -- /garage status` also shows the new capacity.

## Operator-managed StatefulSets (Prometheus)

prometheus-operator owns `prometheus-kube-prometheus-stack`, so step 3 changes `prometheus.prometheusSpec.storageSpec` in the kube-prometheus-stack HelmRelease. Steps 1 and 2 are the same. After the orphan delete, the operator recreates the StatefulSet from the updated `Prometheus` resource.

## Recovering if you merged first

If the HelmRelease is already failed with the `Forbidden` error, run steps 1 and 2, then:

```bash
flux reconcile hr -n <ns> <release> --force
```

Use `--reset` instead if the release is stalled after exhausting its upgrade retries.

## References

- [#557](https://github.com/sp3nx0r/home-ops/pull/557): Garage data volume 50Gi → 1Ti, the first run of this procedure.
