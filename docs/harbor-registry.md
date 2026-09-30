# Harbor container registry

Harbor runs in the `registry` namespace as the cluster's own OCI registry: push/pull for our images and Helm OCI charts, plus pull-through caches for Docker Hub and GHCR. Image blobs live in the Garage S3 `harbor` bucket; Harbor's metadata lives in its bundled PostgreSQL on an `iscsi` PVC backed up by Volsync.

- UI/API: `https://registry.${SECRET_DOMAIN}` (envoy-internal only, not published externally)
- Manifests: `kubernetes/apps/registry/harbor/` (`app/` = chart + policies, `bootstrap/` = API-only config Job)
- Chart: `harbor/harbor` 1.19.2 (Harbor v2.15.2) from `https://helm.goharbor.io`. Harbor publishes no OCI chart, so this uses a `HelmRepository`, the same as Garage.

## Research summary

### What other home-ops repos run

| Repo                | Registry / cache                                                  | Notes                                                                                                                                                                                                                                          |
| ------------------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| onedr0p/home-ops    | **Spegel only**                                                   | No registry, no pull-through cache, no Talos registry mirrors.                                                                                                                                                                                 |
| buroa/k8s-gitops    | Spegel only                                                       | Same approach as onedr0p.                                                                                                                                                                                                                      |
| joryirving/home-ops | Spegel only                                                       | The `dragonfly` there is **DragonflyDB** (a Redis-compatible database), not CNCF Dragonfly.                                                                                                                                                    |
| bjw-s-labs/home-ops | **Zot on the NAS** (docker-compose, outside the cluster) + Spegel | Zot `sync` pull-through for Docker Hub/GHCR with retention, Kanidm OIDC, filesystem storage. Talos `RegistryMirrorConfig` points `docker.io`/`ghcr.io` at it. It runs outside the cluster so image pulls don't depend on the cluster being up. |

The popular repos don't run CNCF Dragonfly. Their "dragonfly" is the database.

### Options compared

|                                | Harbor                                                                                                                                                                                                                                         | Zot                                                                                                                                                                                                  | Dragonfly (CNCF)                                            |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- |
| Real registry (push, Helm OCI) | Yes                                                                                                                                                                                                                                            | Yes                                                                                                                                                                                                  | No. It is a P2P distribution layer in front of a registry.  |
| Pull-through cache             | Proxy-cache projects (API/UI config)                                                                                                                                                                                                           | `sync` extension, declarative JSON                                                                                                                                                                   | Caches through its seed peers, but not a registry of record |
| S3 on Garage                   | distribution S3 driver. Works with `regionendpoint` set: skips AWS region validation and forces path-style. [goharbor/harbor#22773](https://github.com/goharbor/harbor/issues/22773) is the "invalid region: garage" panic you get without it. | Works, but [project-zot/zot#4336](https://github.com/project-zot/zot/issues/4336) (open) empties the metaDB on restart for namespaced repos on S3, which is exactly the `docker-hub/**` proxy layout | Needs its own backend registry                              |
| Dependencies                   | PostgreSQL + Redis/Valkey (bundled by the chart)                                                                                                                                                                                               | None (single binary, local BoltDB metaDB)                                                                                                                                                            | Manager + scheduler + seed peers + MySQL/Redis              |
| OIDC (Pocket ID)               | Native, groups → admin                                                                                                                                                                                                                         | Native (UI/API keys)                                                                                                                                                                                 | N/A                                                         |
| Scanning                       | Trivy built in                                                                                                                                                                                                                                 | Trivy built in (search extension)                                                                                                                                                                    | No                                                          |
| Signatures                     | cosign/notation artifacts stored and shown; content-trust policy per project                                                                                                                                                                   | cosign/notation verification                                                                                                                                                                         | No                                                          |
| Quotas / retention             | Per-project quotas, tag retention, GC jobs                                                                                                                                                                                                     | Retention policies, GC; no quotas                                                                                                                                                                    | N/A                                                         |
| Footprint                      | ~8 pods, ~1 GiB requests incl. Trivy                                                                                                                                                                                                           | 1 pod                                                                                                                                                                                                | Many pods                                                   |
| Overlap with Spegel            | Complementary: durable cache + rate-limit shield, while Spegel only shares what nodes already hold                                                                                                                                             | Complementary                                                                                                                                                                                        | Heavy overlap. Spegel already does node-to-node P2P.        |

**Decision:** Harbor. Dragonfly isn't a registry and would duplicate Spegel. Zot is lighter and fully declarative, and it's the right choice if the registry lives on local disk or the NAS like bjw-s does it. On a Garage S3 backend, though, the open Zot metaDB bug hits the proxy-cache layout. Harbor's per-project quotas also matter here, because Garage is shared with Loki, Thanos, and Pocket ID.

## Architecture

| Component                              | Pod label `component=` | Port(s)                   | State                                                      |
| -------------------------------------- | ---------------------- | ------------------------- | ---------------------------------------------------------- |
| core (API, token service, proxy cache) | `core`                 | 8080, metrics 8001        | stateless                                                  |
| portal (UI)                            | `portal`               | 8080                      | stateless                                                  |
| registry + registryctl                 | `registry`             | 5000 / 8080, metrics 8001 | blobs in Garage `harbor` bucket                            |
| jobservice (GC, retention, scans)      | `jobservice`           | 8080, metrics 8001        | job logs → PostgreSQL                                      |
| trivy adapter                          | `trivy`                | 8080                      | 5Gi `iscsi` vuln-DB cache (re-downloadable, not backed up) |
| database (PostgreSQL)                  | `database`             | 5432                      | `harbor` PVC, 5Gi `iscsi`, **Volsync-backed**              |
| redis (Valkey)                         | `redis`                | 6379                      | 1Gi `iscsi` (queues/sessions, not backed up)               |
| exporter                               | `exporter`             | 8001                      | stateless                                                  |

- **Storage:** `persistence.imageChartStorage.type: s3`, region `garage`, `regionendpoint: http://garage.storage.svc.cluster.local:3900`, `disableredirect: true` (clients can't reach the in-cluster Garage Service, so blobs stream through the registry pod). Garage key `harbor` (`HARBOR_S3_KEY_ID`/`HARBOR_S3_SECRET_KEY` in `cluster-secrets`) has read/write on bucket `harbor` only.
- **Auth:** `core.configureUserSettings` (Harbor's `CONFIG_OVERWRITE_JSON`) sets `auth_mode: oidc_auth` against Pocket ID, `primary_auth_mode: true` (hides the local login form), `oidc_admin_group: harbor_admins`, auto-onboarding, `self_registration: false`, `project_creation_restriction: adminonly`, and a 10 GiB default project quota. Core re-applies this on every start, so UI edits to these settings don't survive a restart; change them in the SOPS secret instead.
- **Secrets:** `app/secret.sops.yaml` holds `harbor-secret` (admin password, `secretKey`) and `harbor-values` (OIDC JSON, DB password, registry htpasswd). The latter is injected with HelmRelease `valuesFrom` + `literal: true` so nothing secret sits in the HelmRelease spec. `harbor-values` disables Flux substitution because bcrypt hashes contain `$`.
- **Exposure:** the chart's Gateway API `HTTPRoute` (`harbor-route`) on `envoy-internal`/`https`, host `registry.${SECRET_DOMAIN}`. UniFi DNS syncs envoy-internal routes automatically. A route-level `BackendTrafficPolicy` replaces the gateway default for this route: no compression, no retries (a retry would replay a partial upload), `requestTimeout: 0s`, `streamIdleTimeout: 15m`. Envoy streams request bodies, so there's no body-size cap to raise.
- **Network policy:** one CNP per component (`app/ciliumnetworkpolicy.yaml`) on top of the default-deny floor. World egress (`0.0.0.0/0` minus private ranges, `:443`) is granted only to core (proxy-cache upstreams) and trivy (vuln DB). Core reaches Pocket ID through the envoy-internal VIP (`:10443`). Only the registry pod may reach Garage `:3900`; Garage's CNP allows it back.
- **Monitoring:** chart ServiceMonitor (`job="harbor"`) plus `app/prometheusrule.yaml`: `HarborAbsent`, `HarborComponentDown` (from `harbor_up`), `HarborRegistryStorageErrors` (registry 5xx ratio), `HarborGarbageCollectionFailing`, `HarborProjectQuotaNearlyFull`. Gatus checks the route (`[STATUS] == 200`).
- **Security context:** the chart's default `containerSecurityContext` (non-root, drop ALL, no privilege escalation, RuntimeDefault seccomp) applies to all containers, and every pod template passes PSA `baseline` admission (server dry-run). `readOnlyRootFilesystem` is **not** set: the chart only exposes one global container security context, and several Harbor images write to their root filesystem (nginx temp dirs, PostgreSQL socket, and so on).
- **Images:** every component is pinned `v2.15.2@sha256:…` (amd64-only manifests, matching the nodes).

### API-only configuration (bootstrap Job)

Proxy-cache endpoints/projects, quotas, tag retention, and the GC schedule are Harbor database objects, not config. `harbor-bootstrap` (a separate Flux Kustomization that `dependsOn: harbor`) runs `bootstrap/bootstrap.py` (stdlib Python, admin basic auth against `harbor-core`). Each step is idempotent:

| Object                     | Setting                                                                                                                                                                                                         |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Registry endpoints         | `dockerhub` (`docker-hub`, `https://hub.docker.com`), `ghcr` (`github-ghcr`, `https://ghcr.io`), anonymous; `dockerhub` authenticates with `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` from `harbor-secret` when set |
| Proxy projects             | `dockerhub`, `ghcr`: public, 15 GiB quota each                                                                                                                                                                  |
| `library` quota            | 10 GiB                                                                                                                                                                                                          |
| Retention (proxy projects) | keep artifacts pulled within the last 90 days, daily 03:00                                                                                                                                                      |
| GC                         | weekly Sunday 04:00, `delete_untagged: true`                                                                                                                                                                    |

Editing the script changes the ConfigMap hash, and `kustomize.toolkit.fluxcd.io/force: enabled` lets Flux replace the Job so it runs again.

Pull through the caches with the project prefix:

```sh
docker pull registry.securimancy.com/dockerhub/library/alpine:3.22
docker pull registry.securimancy.com/ghcr/home-operations/busybox:1.38.0
```

## Capacity

Live Garage state (2026-09-30):

- `data-garage-0`: 50 GiB PVC, **25 GiB used (51%)**. Garage reports 23.9 GiB of 48.9 GiB available.
- Growth: 8.4 GiB (30 days ago) → 17.0 (14d) → 21.1 (7d) → 25.0 GiB, about **0.5 GiB/day**. Loki (17 GiB logical, 30-day retention) should plateau; Thanos (47 GiB logical, raw 14d / 5m 30d / 1h 90d) keeps growing until the 1h tier hits 90 days.
- At that rate Garage fills in about 45 days **without Harbor**, and `GarageDataVolumePredictedToFill` (>50% and a 14-day projection) is about to start firing.

Harbor budget: dockerhub 15 GiB + ghcr 15 GiB + library 10 GiB = **40 GiB**, hard-capped at the storage layer by a Garage bucket quota (`bucket set-quotas harbor --max-size 40GiB` in the garage HelmRelease `clusterConfig.extraCommands`). The Harbor quotas decide who gets rejected first; the Garage quota guarantees Harbor can never take more than 40 GiB from Loki, Thanos, and Pocket ID. New projects default to 10 GiB, so raise the Garage quota before adding more than one project.

**Prerequisite: grow `data-garage-0` to 150Gi before Harbor starts filling caches** (Garage usage plus 40 GiB Harbor plus Thanos growth headroom). `iscsi` supports online expansion. `volumeClaimTemplates` are immutable, so the chart value alone would fail the Helm upgrade:

1. Confirm free space on the TrueNAS pool backing Democratic-CSI.
2. `kubectl -n storage patch pvc data-garage-0 -p '{"spec":{"resources":{"requests":{"storage":"150Gi"}}}}'`, then wait for `FileSystemResizePending` to clear.
3. `kubectl -n storage delete sts garage --cascade=orphan` (the pod keeps running).
4. In a commit: set `persistence.data.size: 150Gi` in `kubernetes/apps/storage/garage/app/helmrelease.yaml`, `capacity: 150Gi` in `garage-data-dst` (`volsync.yaml`), and consider raising the `garage-data` Kopia `cacheCapacity`. Flux recreates the StatefulSet with the new template.
5. Garage's layout capacity (`garage status`) is informational for a single node, so no layout change is needed.

Backup side effect: `garage-data` is snapshotted hourly into the shared Kopia repo on NFS. Proxy-cache blobs deduplicate but are retained for 24 hourly and 7 daily snapshots after Harbor deletes them, so expect NAS Kopia usage to grow by roughly the Harbor bucket size.

## Manual steps

### Before merge

1. Expand Garage (see [Capacity](#capacity)).
2. In Pocket ID (`https://id.securimancy.com`, admin): create group `harbor_admins` and add yourself. Create an OIDC client:
    - Name `Harbor`, callback URL `https://registry.securimancy.com/c/oidc/callback`
    - Not public (confidential client), PKCE off (Harbor doesn't send PKCE)
    - Allowed groups: whoever should be able to log in (optional)
3. Put the client ID and secret into the SOPS secret:

    ```sh
    export SOPS_AGE_KEY_FILE=/opt/home-ops/age.key
    sops kubernetes/apps/registry/harbor/app/secret.sops.yaml
    # harbor-values.configureUserSettings: replace REPLACE_WITH_POCKET_ID_CLIENT_ID / _SECRET
    ```

    If you skip this, Harbor still starts. OIDC login fails until it's fixed, and the local admin login keeps working.

### After merge

1. Watch `flux get ks -n registry` until `harbor` and `harbor-bootstrap` are Ready. `kubectl -n registry logs job/harbor-bootstrap` should end with `harbor bootstrap complete`.
2. Log in via **Login via OIDC provider** and confirm your user is an admin (member of `harbor_admins`).
3. The local `admin` account can't be deleted or disabled in Harbor, and it stays reachable at `/account/sign-in` even in OIDC primary mode. Its password is a random 48-character value in `harbor-secret`, and the bootstrap Job uses it. Don't hand it out; use robot accounts for automation.
4. Docker CLI as an OIDC user: copy the **CLI secret** from _User Profile_ and run `docker login registry.securimancy.com -u <username>`. For CI/Flux, create a project-scoped robot account.
5. Helm OCI: `helm push chart.tgz oci://registry.securimancy.com/library`.
6. Confirm scanning works: _Interrogation Services → Scanners_ shows Trivy healthy; scan an artifact.
7. Signatures: pushing `cosign sign` or `notation sign` output stores the signature as an accessory. Enable _Content trust_ per project to block unsigned pulls if desired.

## Backup and restore

- **PostgreSQL** (`harbor` PVC): the volsync component runs hourly `ReplicationSource harbor` (24 hourly, 7 daily) to the shared Kopia repo, with the mover as uid/gid 999 to match `PGDATA` 0700. Snapshots are **crash-consistent**: an atomic iSCSI/ZFS block snapshot of a running database, the same as a power cut. PostgreSQL replays WAL on start, which is normally safe, but it isn't a logical backup. Follow-up: a nightly `pg_dump` CronJob to NFS.
- **Blobs**: in Garage, covered by the `garage-data`/`garage-meta` ReplicationSources (also hourly at `:00`). The DB and blob snapshots are taken independently, so a restore can have manifests pointing at missing blobs (re-push, or for proxy projects let the cache refetch) or orphan blobs (reclaimed by the next GC).
- **Secrets**: `harbor-secret.secretKey` decrypts registry-endpoint credentials and the OIDC client secret stored in the DB. It's in git (SOPS), and it must match the restored DB.
- **Restore** (DB): `just volsync restore` assumes an app-template controller named `harbor`, so it fails here at the scale step. Do it by hand:
    1. `flux -n registry suspend ks harbor-bootstrap harbor && flux -n registry suspend hr harbor`
    2. `kubectl -n registry scale deploy,sts -l app=harbor --replicas=0`, then wait for the pods to terminate.
    3. Render `volsync/resources/replicationdestination.tmpl.yaml` with `NS=registry APP=harbor CLAIM=harbor CAPACITY=5Gi PUID=999 PGID=999 PREVIOUS=<n>` (`envsubst | kubectl apply --server-side -f -`), wait for `job/volsync-dst-harbor-manual` to complete, then delete `replicationdestination/harbor-manual`.
    4. Resume the HelmRelease and both Kustomizations, then `flux -n registry reconcile hr harbor --force`.
- **Not backed up**: Valkey (queues/sessions) and the Trivy cache. Both are rebuilt automatically.

## Follow-ups / open questions

- **Talos containerd mirrors** (deliberately not done): pointing `docker.io`/`ghcr.io` at `https://registry.securimancy.com/v2/{dockerhub,ghcr}/` with `overridePath: true` would make Harbor a node-level cache. The chicken-and-egg problem is that Harbor, Envoy, Cilium, Garage, and iSCSI must all be running to serve pulls. It's only safe with containerd's default fallback to upstream (never `skipFallback`), with Spegel listed first. An alternative is bjw-s' layout (registry on the NAS, outside the cluster).
- **Docker Hub rate limits**: anonymous upstream pulls are rate-limited per IP. Set a Docker Hub PAT (read-only scope) in the `harbor-secret` document of `kubernetes/apps/registry/harbor/app/secret.sops.yaml` (`sops set <file> '["stringData"]["DOCKERHUB_TOKEN"]' '"<pat>"'`, same for `DOCKERHUB_USERNAME`). The bootstrap Job re-applies it on every run, but a secret-only change does not re-run the Job: after rotating the token, re-run it with `kubectl -n registry delete job harbor-bootstrap && flux reconcile ks harbor-bootstrap -n registry`.
- More upstreams (`quay.io`, `registry.k8s.io` as `docker-registry` type) can be added to `PROXY_CACHES` in `bootstrap.py`. Keep the quota sum under the Garage bucket quota.
- A logical `pg_dump` backup; Harbor webhooks → Discord for scan findings (needs jobservice world egress).
