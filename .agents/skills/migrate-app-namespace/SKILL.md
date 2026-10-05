---
name: migrate-app-namespace
description: Moves a home-ops app between namespaces while keeping its PVC data and leaving no orphans. Covers the reference inventory, the GitOps PR, a human-run PV retain-and-rebind cutover (no data copy) with rollback points, and cleanup of objects a suspended Kustomization leaves behind. Use when relocating an app for PSA level, isolation or reorganisation, splitting a namespace, or moving a subchart component to its own release.
---

# Migrate an app between namespaces

## Mission

Relocate an app's GitOps tree, every reference to its old namespace, and its network policy, while keeping its data without a copy, with a rollback point at each step, and with nothing left behind in the old namespace.

## Prerequisites

- Prior run: `qbittorrent-gluetun` `media` → `download` ([#497](https://github.com/sp3nx0r/home-ops/pull/497), consumer fix [#534](https://github.com/sp3nx0r/home-ops/pull/534)). Use `kubernetes/apps/download/` as the layout example.
- The `iscsi` StorageClass reclaim policy is **`Delete`**: deleting a PVC whose PV is still `Delete` destroys the zvol. Every PV must be `Retain` before any PVC is deleted.
- Cutover steps are live changes. The user runs them, or approves each one.
- Related skills: `cilium-cnp-authoring` (consumer/server policy), `flux-rollout-watch` (post-merge checks), `hubble-drop-triage`.

## Workflow

### 1. Inventory (read-only)

Find everything that names the old namespace, not just the app's own directory:

```sh
APP=<app>; OLD=<old>; NEW=<new>
kubectl -n $OLD get ks,hr,deploy,sts,pvc,svc,httproute,cronjob,replicationsource,replicationdestination | rg "$APP|NAME"
kubectl get pv -o json | jq -r --arg ns $OLD '.items[] | select(.spec.claimRef.namespace==$ns)
  | "\(.metadata.name)\t\(.spec.claimRef.name)\t\(.spec.persistentVolumeReclaimPolicy)\t\(.spec.capacity.storage)"'
rg -n "$APP\.$OLD(\.svc)?" kubernetes/                            # in-cluster DNS consumers
rg -n -B3 -A3 "io.kubernetes.pod.namespace: $OLD" kubernetes/apps -g '*ciliumnetworkpolicy.yaml' | rg -B3 -A3 "$APP"
rg -n "namespace=\\\\?\"$OLD\\\\?\"|source=\\\\?\"$OLD/" kubernetes/  # PromQL/LogQL in rules, dashboards, alert exclusions
rg -n "namespace: $OLD" kubernetes/apps -g '!kubernetes/apps/'"$OLD"'/**' # dependsOn, RBAC, refs from other apps
rg -n 'lbipam.cilium.io/ips' kubernetes/apps/$OLD/$APP                  # pinned LB IPs
rg -n dataSourceRef kubernetes/apps/$OLD/$APP                          # PVCs restored from Volsync on create
```

Classify each PVC to pick the data path:

| Data                                                                  | Path                                                                                                                                                                                 |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| No PVC, or only inline NFS volumes (`/mnt/tank/...`)                  | Stateless: merge and reconcile. NFS paths don't depend on the namespace.                                                                                                             |
| `pvc.yaml` in the app dir (app-template `existingClaim`)              | **PV rebind** (§3). Tested path.                                                                                                                                                     |
| StatefulSet `volumeClaimTemplates` (loki, thanos, garage, prometheus) | PV rebind, but pre-create each PVC named `<template>-<sts>-<ordinal>` in `$NEW` with `volumeName`; the StatefulSet adopts PVCs by name. Not yet exercised here, so dry-run it first. |
| Volsync cache / `-dst` PVCs                                           | Don't move; they're regenerated.                                                                                                                                                     |

Ask how external consumers reach the app. A runtime UI setting (an *arr download-client host) may use the external hostname and need no change.

### 2. GitOps PR

```sh
mkdir -p kubernetes/apps/$NEW && git mv kubernetes/apps/$OLD/$APP kubernetes/apps/$NEW/$APP
```

- New namespace (if needed): copy `kubernetes/apps/download/{namespace,kustomization}.yaml`. That gives the `kustomize.toolkit.fluxcd.io/prune: disabled` annotation, the PSA `enforce` label (Kyverno denies namespaces without it), and `components: [../../components/sops]`. New namespace dirs are discovered automatically. Update the AGENTS.md namespace table.
- `<app>/ks.yaml`: update `path:` and `targetNamespace:`. Cross-namespace `dependsOn` entries need `namespace:`.
- Remove `./<app>/ks.yaml` from `kubernetes/apps/$OLD/kustomization.yaml`.
- Fix every inventory hit:
    - `<app>.<old>.svc` → `<app>.<new>.svc`, **and** the consumer's CNP egress `toEndpoints` namespace. A missed consumer CNP fails silently: seasonpackerr lost its egress to qbittorrent-gluetun after the move, and nobody noticed until a later audit (#534).
    - Server CNPs that select the app by namespace (e.g. Loki ingress): allow both namespaces if pods with the same labels stay behind.
    - `namespace="<old>"` in PrometheusRules, Grafana dashboards, kromgo config and `HubblePolicyDenied` exclusions (`source="<old>/<app>"`). Missed ones become alerts that never fire.
- Each PVC being rebound: add `volumeName: <pv>` to `pvc.yaml`, keeping `storageClassName`, `accessModes` and size identical.
- Validate: `kustomize build kubernetes/apps/$NEW/$APP/app`, plus a server dry-run of the CNP and namespace. Open the PR and **tell the user not to merge until §3 steps 0–2 are done**.

### 3. Stateful cutover (steps 0–2 before merge)

```sh
PVS="<pv1> <pv2>"                                    # from the inventory
# 0. Rollback point: a fresh backup under the OLD identity
just volsync snapshot $APP $OLD
# 1. Protect every PV
for pv in $PVS; do kubectl patch pv $pv -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'; done
kubectl get pv $PVS -o custom-columns=N:.metadata.name,R:.spec.persistentVolumeReclaimPolicy   # all Retain
# 2. Quiesce. Suspend first, or Flux scales it back up
flux -n $OLD suspend ks $APP
kubectl -n $OLD scale deploy,sts -l app.kubernetes.io/instance=$APP --replicas=0
kubectl -n $OLD get pods | rg $APP                   # wait until empty; no writer may hold the volume
# --- user merges + reconciles; new PVCs sit Pending (PVs still claimed) ---
# 3. Release each PV: delete the old PVC, then clear its claimRef (→ Available)
kubectl -n $OLD delete pvc <claim> --wait=true
kubectl patch pv <pv> --type=merge -p '{"spec":{"claimRef":null}}'
# 4. Rebind and start
kubectl -n $NEW wait --for=jsonpath='{.status.phase}'=Bound pvc/<claim> --timeout=120s   # per claim; volsync -dst PVCs stay Pending
kubectl -n $NEW get pods -w | rg $APP                # Ready, not CrashLoop
# 5. Prove the data came across (not a fresh init): file count and newest mtimes in the data dir
kubectl -n $NEW exec <pod> -c <container> -- sh -c 'ls -la <data-dir>; find <data-dir> -type f | wc -l'
# 6. Clean up orphans (see Gotchas), then restore the reclaim policy
for pv in $PVS; do kubectl patch pv $pv -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'; done
# 7. Start the new backup chain and confirm it completes
just volsync snapshot $APP $NEW
```

Rollback by stage:

- **Before merge**: close the PR, `flux -n $OLD resume ks $APP`.
- **Merged, before step 3**: the old PVCs and data are untouched. Revert the PR; the old Kustomization comes back, then scale up.
- **After step 3**: the PVs are `Retain` and `Available`/re-bound. To go back, run the same release-and-rebind in reverse, with `volumeName` in the old namespace.
- **Data wrong after step 5**: restore the step-0 snapshot into `$NEW` with a one-off ReplicationDestination that sets `sourceIdentity.sourceName: $APP` **and `sourceNamespace: $OLD`** (`docs/backup-and-recovery/runbook-restore-pvc.md`, "Cross-namespace restore").

### 4. Validate

- From a consumer pod: `http://<app>.<new>.svc.cluster.local:<port>/`, then the external hostname.
- HTTPRoute `Accepted=True`; Prometheus target `up`; no drops for the app or its consumers.
- Old namespace sweep returns nothing (see the first Gotcha).
- If the move was for PSA, dry-run the old namespace's tighter level, then change it in a follow-up PR: `kubectl label ns $OLD pod-security.kubernetes.io/enforce=baseline --overwrite --dry-run=server`.

### Subchart variant (stateless, e.g. node-exporter → kube-system)

Disable the subchart and add a standalone OCI chart at the same version. Set `fullnameOverride` to the old name so the `job` label and dashboards keep working, and compare with the live ServiceMonitor `jobLabel`/relabelings.

## Gotchas & Edge Cases

- **A suspended Kustomization skips garbage collection.** Merging removes the old `ks.yaml`, so the parent prunes the suspended Kustomization object, but its inventory is never garbage-collected. After the gluetun move, the old namespace still held the HelmRelease, OCIRepository, ReplicationSource (still backing up), ReplicationDestination, cache PVC, Secrets, and the cache-scrub CronJob with its SA/Role/RoleBinding. Sweep, delete the HelmRelease first, then the rest by name, and repeat until empty:
    ```sh
    kubectl -n $OLD get hr,ocirepository,deploy,sts,svc,pvc,secret,cm,cronjob,sa,role,rolebinding,replicationsource,replicationdestination,httproute | rg $APP
    ```
- **The leftover old Service still holds a pinned LB IP.** The new Service stays `<pending>` until the old one is deleted. Delete the old Service right after the rebind.
- **The Volsync identity changes.** The component's ReplicationDestination sets only `sourceName: ${APP}`, so the namespace defaults to the new one. Old snapshots stay in Kopia under the old identity and are reachable only through an explicit `sourceNamespace`. `volsync-dst-*` pods `Pending` in the new namespace are harmless (`trigger.manual: restore-once`, nothing to restore yet).
- **Kustomize's `namespace:` transformer renames Namespace objects.** To adopt existing system namespaces (labels only), use a sub-Kustomization without `namespace:` (pattern: `kubernetes/apps/kube-system/system-namespaces/`).
- `flux-system` is owned by flux-operator; Git labels on it never apply ([#522](https://github.com/sp3nx0r/home-ops/pull/522)).
- **A PSA server dry-run only sees running pods.** It missed tuppr's transient privileged upgrade Jobs in `system-upgrade`. `hostPath` alone is allowed under baseline.
- App Kustomizations live in the app's namespace: `flux -n $OLD suspend ks $APP`, not the default `flux-system`.

## Output Template

```
## <app>: <old> → <new>
PR: [#<n>](https://github.com/sp3nx0r/home-ops/pull/<n>)
Inventory: PVCs <claim→pv, size> · consumers <files> · consumer CNPs <files> · namespace-labelled rules/dashboards <files> · LB IP <ip|none>
Cutover: snapshot@old ✓ → Retain ✓ → quiesced ✓ → merged → claimRef cleared ✓ → Bound ✓ → Ready ✓ → data proof ✓ → Delete ✓ → snapshot@new ✓
Data proof: <file count + newest mtimes>
Orphans removed: <list> (final sweep empty ✓)
E2E: consumer → svc <code> · external <code> · target up · drops none
Follow-up: <old> enforce=<level> PR
```
