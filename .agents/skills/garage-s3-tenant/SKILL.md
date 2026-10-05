---
name: garage-s3-tenant
description: Adds a least-privilege S3 tenant (key + bucket, optional quota) to the in-cluster Garage in home-ops and wires the client app — capacity and runway check on the shared data volume, credentials generated straight into cluster-secrets without printing them, Garage HelmRelease clusterConfig entries, Garage CNP ingress for only the S3-doing pod, app-side endpoint/region/path-style settings, and the separate manual procedure for growing the Garage StatefulSet PVC. Use when an app needs object storage (registry, backups, Loki/Thanos-style tenants) or when Garage capacity is running low.
---

# Garage S3 tenant

## Mission

Give a new app S3 access to Garage without starving the existing tenants (Loki, Thanos, Pocket ID) on the shared volume or leaking credentials.

## Prerequisites

- Worktree with `age.key` + kubeconfig symlinked (`home-ops-worktree-pr`). Read-only `kubectl exec` into `storage/garage-0`.
- Facts: data PVC `data-garage-0` is **1Ti**, meta `meta-garage-0` 5Gi (iSCSI, expandable). Volsync backs **both up hourly** (`garage-data`, `garage-meta` ReplicationSources), so every tenant byte also grows the Kopia repo on the NAS.
- Alert: `GarageDataVolumePredictedToFill` in `kubernetes/apps/o11y/kube-prometheus-stack/app/prometheusrule.yaml`.
- `source /opt/home-ops/scripts/o11y.sh` for `tq`.

## Workflow

1. **Capacity first (read-only)**:
    ```sh
    kubectl -n storage exec garage-0 -- /garage status        # Capacity + DataAvail
    kubectl -n storage exec garage-0 -- /garage bucket list
    kubectl -n storage exec garage-0 -- /garage bucket info <bucket> | rg -i 'size|objects'
    for o in "" " offset 7d" " offset 30d"; do tq "max(kubelet_volume_stats_used_bytes{persistentvolumeclaim=\"data-garage-0\"}$o)/2^30" | jq -r .v; done
    ```
    Compute GiB/day and the runway. Thanos grows until its 90-day retention; Loki plateaus at 30 days. Size the tenant's budget against the remaining space.
2. **Generate credentials straight into cluster-secrets** without printing them. Format (documented in the Garage HR): keyId = `GK` + 24 hex chars, secret = 64 hex chars.
    ```sh
    f=kubernetes/components/sops/cluster-secrets.sops.yaml
    sops set "$f" '["stringData"]["<APP>_S3_KEY_ID"]' "\"GK$(openssl rand -hex 12)\""
    sops set "$f" '["stringData"]["<APP>_S3_SECRET_KEY"]' "\"$(openssl rand -hex 32)\""
    sops -d "$f" | yq '.stringData | with_entries(select(.key|test("<APP>"))) | map_values(length)'   # lengths only: 26 and 64
    ```
    `cluster-secrets.sops.yaml` is a hot spot for parallel PRs; expect a rebase. Use **one** variable pair, read by both Garage and the app (see the Loki gotcha).
3. **Declare key and bucket** in `kubernetes/apps/storage/garage/app/helmrelease.yaml`, both places, alphabetical:
    - `clusterConfig.keys.<app>`: `keyId: "${<APP>_S3_KEY_ID}"`, `secretKey: "${<APP>_S3_SECRET_KEY}"`, `buckets: [{name: <app>, read: true, write: true}]`.
    - `clusterConfig.buckets`: `- name: <app>` with `keys: [{name: <app>, permissions: ["read", "write"]}]`.
      The configure hook validates both formats and exits 1 on a mismatch, which fails the Helm upgrade.
4. **Hard cap** for tenants that can grow without bound: the pinned chart (0.8.0) runs `clusterConfig.extraCommands` at the end of the configure hook as `garage <cmd>`, so add `- bucket set-quotas <app> --max-size <N>GiB` there (flags: `/garage bucket set-quotas --help`). Unlike the built-in steps, extra commands have no `|| true`: a typo fails the hook and the upgrade. Keep the cap above the app's own quotas and below free space. Re-check the template after a chart bump (`helm pull garage --repo https://datahub-local.github.io/garage-helm --version <v> --untar`, then `templates/secret-configure.yaml`).
5. **Garage CNP ingress** (`kubernetes/apps/storage/garage/app/ciliumnetworkpolicy.yaml`): add `fromEndpoints` for **only the pod doing S3 I/O** (e.g. Harbor `component: registry`) on `3900`, and update the comment listing tenants. A chart hook that calls Garage's admin `:3903` needs its own rule; see `flux-rollout-watch` § D for what happens when it doesn't.
6. **App side**:
    - Endpoint `garage.storage.svc.cluster.local:3900`, region `garage`, path-style addressing (copy from `kubernetes/apps/o11y/loki/app/helmrelease.yaml`).
    - Egress in the client's CNP to `storage` Garage pods on `3900`.
    - Credentials: a plain `secret.yaml` using `${<APP>_S3_KEY_ID}`/`${<APP>_S3_SECRET_KEY}` (model: `kubernetes/apps/o11y/kube-prometheus-stack/app/secret.yaml`, Thanos `objstore.yml`), plus `substituteFrom: cluster-secrets` in the app's `ks.yaml` (not every `ks.yaml` has it). Garage reads the same variables, so both sides stay in sync. Loki and Pocket ID substitute keys straight into HelmRelease values, where anyone who can read HelmReleases sees them; don't copy that.
7. **Disable presigned redirects** for anything clients download through (registry `storage.redirect.disable: true`). Otherwise clients are redirected to an internal hostname they can't reach.
8. Validate (`home-ops-change-validation`) and ship as a PR. Post-merge: `garage bucket info <app>` shows the key (and the quota, if set), and the app writes an object. Don't trust a green hook alone (see Gotchas).

## Growing the Garage data volume (separate change)

`volumeClaimTemplates` are immutable, so bumping the size in the HR alone fails the Helm upgrade (and then the rollback, see `flux-rollout-watch` § D). The procedure used for 1Ti ([#557](https://github.com/sp3nx0r/home-ops/pull/557)), run by the owner:

1. `kubectl -n storage patch pvc data-garage-0 -p '{"spec":{"resources":{"requests":{"storage":"<new>"}}}}'` and wait until `.status.capacity` shows it.
2. `kubectl -n storage delete sts garage --cascade=orphan` (pod and PVC keep running).
3. Merge the commit with the new `persistence.data.size` (the layout capacity defaults to it) and the matching `capacity` on `garage-data-dst` in `app/volsync.yaml` (Garage doesn't use `VOLSYNC_CAPACITY`), then reconcile.
4. Verify the HR is Ready, the sts template shows the new size, and `/garage status` shows the new capacity.
   Before merging, make sure no chart hook will hang on a CNP gap. A hook timeout rolls back and recreates the old template.

## Gotchas & Edge Cases

- **The configure hook swallows errors and never deletes.** `key import` and `bucket allow` end in `|| true`, so a failed import still shows a green hook. Removing a key or bucket from values leaves it in Garage. Changing only the secret of an existing `keyId` does nothing: Garage rejects the re-import with `KeyAlreadyExists` and the hook ignores it, so the app gets the new secret and Garage keeps the old one. Rotate with a new key ID too, then remove the old key by hand (`garage key delete`).
- **The hook takes over 3 minutes by design** (`sleep 60` before, `sleep 120` after). Don't treat a running `garage-configure` Job as hung before ~4 minutes.
- **Loki has duplicate variables.** Garage's `loki` key reads `GARAGE_S3_KEY_ID`/`_SECRET_KEY`, and Loki reads `LOKI_S3_KEY_ID`/`_SECRET_KEY`. The values match today; rotate both pairs together or Loki loses access.
- Distribution-based registries panic on region `garage` when no `regionendpoint` is set ([harbor#22773](https://github.com/goharbor/harbor/issues/22773), closed because setting it is the fix). Set the endpoint.
- Zot on S3 has an open metaDB-reset bug for namespaced repos ([zot#4336](https://github.com/project-zot/zot/issues/4336)). Avoid Zot+Garage for pull-through caches.
- Never print secret values. Compare silently (`[ "$(sops -d f | yq .stringData.X)" = "$expected" ] && echo match`) or print lengths.
- Garage is single-replica (`replicaCount: 1`). Its CNP already allows the configure hook to reach admin `:3903`; keep that rule when editing.

## Output Template

```
Garage capacity: <used>/1024 GiB (<pct>%), +<x> GiB/day, ~<n> days runway; tenant budget <y> GiB (quota: <how>)
Changes: garage HR key+bucket, garage CNP ingress from <ns>/<pod>:3900, cluster-secrets +<APP>_S3_KEY_ID/_SECRET_KEY (lengths verified)
App: endpoint/region/path-style, egress CNP, secret.yaml via substituteFrom
Post-merge: <quota command if needed>, write test
Prereq: grow data-garage-0 to <size> (separate change) if runway < 60d
```
