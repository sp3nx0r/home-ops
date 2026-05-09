# Syslog & Centralized Logging Plan

> Goal: Add centralized log collection, storage, and querying to the cluster.
> Ingest syslog from the UniFi UDM and TrueNAS NAS, collect Kubernetes pod/node
> logs, and provide search/query via Grafana + LogQL.

## Architecture Overview

```
┌──────────────┐    ┌──────────────┐
│  UniFi UDM   │    │  TrueNAS HL8 │
│ 192.168.5.1  │    │ 192.168.5.40 │
└──────┬───────┘    └──────┬───────┘
       │ UDP 514           │ UDP 514
       │   (syslog)        │   (syslog)
       └──────┬────────────┘
              ▼
┌─────────────────────────────────┐
│  Vector (Deployment)           │  ← LoadBalancer 192.168.5.24
│  syslog source                 │     syslog listener for external devices
│  → loki sink                   │
└─────────────────────────────────┘

┌─────────────────────────────────┐
│  Vector (DaemonSet)            │  ← one pod per node (3 total)
│  kubernetes_logs source        │     pod logs from all namespaces
│  → loki sink                   │
└──────────────┬──────────────────┘
               ▼
┌─────────────────────────────────┐
│  Loki (single binary)          │  ← 1 pod, ~512MB–1GB RAM
│  TSDB index + snappy chunks    │
│  30-day retention, compactor   │
│  → S3 API (chunks + index)     │
└──────────────┬──────────────────┘
               ▼
┌─────────────────────────────────┐
│  Garage (S3-compatible)        │  ← 1 pod, ~50MB
│  data on iSCSI PVC (50 Gi)     │     backed by TrueNAS zvol
└─────────────────────────────────┘
               ▼
┌─────────────────────────────────┐
│  Grafana                       │  ← add Loki datasource
│  LogQL queries + dashboards    │     alongside existing Prometheus
└─────────────────────────────────┘

Future (tracing):
┌─────────────────────────────────┐
│  App instrumentation (OTLP)    │
│  → Vector (opentelemetry src)  │  ← or OTel Collector if needed
│  → Tempo (trace backend)       │
│  → Grafana (trace UI)          │
└─────────────────────────────────┘
```

---

## Component Selection

### Versions (as deployed)

| Component | Chart | App Version | Image |
|---|---|---|---|
| Loki | grafana-community/loki 9.4.5 (OCI) | 3.7.1 | grafana/loki |
| Vector | vectordotdev/vector 0.52.0 (OCI) | 0.55.0 | timberio/vector |
| Garage | datahub-local/garage 0.5.0 (Helm) | v2.3.0 | dxflrs/garage |

### Log Aggregator: Grafana Loki

**Why Loki:**

- Native Grafana companion — add a datasource and LogQL is available in the
  same Grafana instance we already run
- Label-indexed, not full-text — same mental model as Prometheus, dramatically
  cheaper on storage than Elasticsearch/OpenSearch
- Loki ruler can fire alerts to our existing Alertmanager → Discord pipeline
- Single Helm chart, well-maintained, huge community

**Alternatives considered and rejected:**

| Alternative | Why not |
|---|---|
| Elasticsearch / OpenSearch | 2–4 GB RAM minimum per node, JVM tuning, massively overkill |
| VictoriaLogs | Promising but young, weaker Grafana integration |
| Graylog | Requires MongoDB + Elasticsearch, too heavy |

**Deployment mode: Single Binary (Monolithic)**

The cluster will produce ~1–5 GB/day of logs. Single binary handles up to
~20 GB/day in a single pod. The "Simple Scalable" mode deploys 10+ pods and
is being deprecated before Loki 4.0. Monolithic mode = 1 pod, ~512MB–1GB RAM.

### Log Collector: Vector

Vector (by Datadog, originally Timber) is a high-performance observability
data pipeline written in Rust. It replaces Grafana Alloy/Promtail as the log
collector.

**Why Vector over Alloy:**

| | Alloy | Vector |
|---|---|---|
| Language | Go | Rust |
| Memory footprint | ~100 MB | **~30–50 MB base** (see note below) |
| Config language | Alloy/River (Grafana-specific) | **TOML** (standard) |
| Transform engine | `loki.process` stages | **VRL** (full expression language) |
| Vendor lock-in | Grafana ecosystem | **Vendor-neutral**, any sink |
| Trace support | Native OTLP | OTLP source + sink (passthrough) |
| License | Apache 2.0 | MPL 2.0 |

Key advantages:
- **VRL (Vector Remap Language)** — a proper programming language for log
  transforms, far more powerful than Alloy's pipeline stages for parsing,
  enriching, and routing
- **Career alignment** — used at work, homelab builds hands-on expertise
- **Future trace support** — Vector can receive OTLP traces and forward to
  Tempo, acting as a basic trace pipeline until OTel Collector is needed

> **Memory reality check:** Vector's advertised ~30–50 MB footprint is for
> a bare process. The `kubernetes_logs` source maintains a Kubernetes API
> watch, per-pod metadata, and a file reader per active container log file.
> Observed steady-state memory scales roughly linearly with pod count:
> ~634 Mi (15 pods), ~666 Mi (30 pods), ~1215 Mi (41 pods). Plan for
> ~15–30 MB per pod on the node, not 30–50 MB total. The syslog Deployment
> (push-based, no file readers) genuinely runs at ~26 Mi.

Two deployment patterns:

1. **DaemonSet** — one pod per node for Kubernetes pod log scraping via
   `kubernetes_logs` source
2. **Deployment** (standalone) — syslog listener with a LoadBalancer IP so
   external devices (UDM, NAS) can send syslog to a stable address

The syslog Deployment uses Vector's `syslog` source which supports both
RFC5424 (UDM) and RFC3164 (TrueNAS) formats over UDP.

### Object Storage: Garage

**Why Garage over SeaweedFS:**

| | SeaweedFS | Garage |
|---|---|---|
| Language | Go | Rust |
| Memory footprint | ~512 MB minimum | **~50 MB** |
| Binary size | ~100 MB+ | **~20 MB** |
| Architecture | Master + Volume + Filer + S3 (4 components) | **Single binary** (all-in-one) |
| Setup complexity | Medium | **Very low** |
| License | Apache 2.0 | AGPL v3 (fine for internal use) |
| Data protection | Erasure coding + replication | Replication only |

RAM matters — 32 GB per node is shared with Prometheus (2 GB), Grafana, Plex,
and all other workloads. SeaweedFS eating 512 MB+ across its four component
types is expensive. Garage uses ~50 MB per instance.

Our log volume is small — we don't need erasure coding or SeaweedFS's
high-file-count optimizations. Loki talks to any S3 API, so if Garage doesn't
work out, we can swap in SeaweedFS with a config change.

**Why NOT SeaweedFS:**
Not that it wouldn't work — it absolutely would. But Garage is purpose-built
for this exact scale. SeaweedFS shines at high file counts and mixed workloads
that we don't have. Save the complexity for environments that need it (work).

### Why Garage Runs In-Cluster, Not On TrueNAS

It's tempting to run Garage directly on TrueNAS since "the storage lives
there." But this is the wrong trade-off for several reasons:

1. **GitOps model breaks** — every other workload is managed by Flux from this
   repo. A service running on TrueNAS is a snowflake that needs manual
   management, SSH access, and separate monitoring. We'd need Ansible playbooks
   to manage it, which is a different ops model than the rest of the stack.

2. **Data locality is a red herring** — Garage in-cluster with an iSCSI PVC
   stores its data on TrueNAS anyway (as a zvol). The data path is:
   `Loki → Garage → iSCSI → TrueNAS ZFS`. The extra network hop is over
   10 GbE SFP+ and adds negligible latency for log storage writes.

3. **Failure domain coupling** — if Garage runs on TrueNAS and TrueNAS
   reboots, Loki loses its storage backend *and* the syslog source goes down
   simultaneously. In-cluster, Garage survives TrueNAS maintenance windows
   (it buffers to its PVC; writes resume when iSCSI recovers).

4. **TrueNAS app ecosystem is unstable** — TrueNAS SCALE deprecated k3s-based
   apps, moved to Docker Compose, and the app platform has been in flux.
   Running a critical storage dependency on a shifting platform is risky.

5. **Observability gap** — in-cluster Garage gets Prometheus ServiceMonitor
   scraping, Grafana dashboards, and alerting for free. On TrueNAS, we'd need
   to separately configure monitoring.

**Bottom line:** The data ends up on TrueNAS disks either way. Keep the
workload in the cluster where Flux manages it.

---

## Network & IP Allocation

### Existing LoadBalancer IPs

| IP | Service |
|---|---|
| 192.168.5.2 | k8s-gateway |
| 192.168.5.10 | envoy-internal |
| 192.168.5.20 | envoy-external |
| 192.168.5.21 | Plex |
| 192.168.5.22 | tor-relay |

### New Allocation

| IP | Service | Protocol |
|---|---|---|
| **192.168.5.24** | Vector syslog listener | UDP 514 |

Cilium L2 announcement policy already covers the full 192.168.5.0/24 CIDR
(`CiliumLoadBalancerIPPool` in `kube-system/cilium/app/networks.yaml`). No
pool changes needed.

---

## Syslog Source Configuration

### UniFi Dream Machine (192.168.5.1)

1. **Settings → Logging → Remote Syslog** → enable
2. Server: `192.168.5.24`
3. Port: `514`
4. Protocol: UDP
5. Log level: Info (or Debug for more verbosity)

**Known limitation:** Standard remote syslog does not forward firewall/traffic
logs. Those require UniFi Network Application v9.3+ with CEF format export
(Settings → Control Plane → Integrations → Activity Logging). Standard device
syslog covers: AP events, switch events, controller events, system logs.

### TrueNAS SCALE (192.168.5.40)

1. **System → Advanced → Syslog**
2. Remote Syslog Server: `192.168.5.24:514`
3. Transport: UDP
4. Level: Info

Covers: ZFS events, pool scrub/resilver, SMB/NFS service logs, SMART alerts,
system daemon logs.

---

## Loki Configuration

### Key Parameters

| Parameter | Value | Rationale |
|---|---|---|
| Deployment mode | `SingleBinary` | <20 GB/day, 1 pod |
| Schema | v13 (TSDB) | Current recommended schema |
| Object store | S3 (Garage) | `s3ForcePathStyle: true` required for non-AWS |
| Chunk encoding | snappy | Fast compression, good for logs |
| Retention | 30 days (720h) | Configurable via `limits_config.retention_period` |
| Replication factor | 1 | Single binary mode |
| Structured metadata | enabled | Required for schema v13 |

### Helm Values (as deployed)

See `kubernetes/apps/o11y/loki/app/helmrelease.yaml` for the full
HelmRelease. Key values that differ from chart defaults:

```yaml
loki:
  auth_enabled: false
  limits_config:
    retention_period: 720h                # 30 days
    ingestion_rate_mb: 16                 # raised from default 4
    ingestion_burst_size_mb: 32           # raised from default 6
    per_stream_rate_limit: 5MB            # raised from default 3MB
    per_stream_rate_limit_burst: 15MB     # raised from default 15MB
    reject_old_samples: true
    reject_old_samples_max_age: 168h      # 7 days — prevents 400s from late entries
  storage:
    s3:
      endpoint: garage.storage.svc.cluster.local:3900
      s3ForcePathStyle: true
      insecure: true                      # in-cluster traffic, no TLS needed

singleBinary:
  persistence:
    storageClass: iscsi                   # TrueNAS-backed zvol
    size: 5Gi

monitoring:
  serviceMonitor:
    enabled: true                         # Prometheus scraping for dashboards
```

Credentials are sourced from `cluster-secrets` via Flux `postBuild`
variable substitution (`${LOKI_S3_KEY_ID}`, `${LOKI_S3_SECRET_KEY}`).

---

## Vector Configuration

See the HelmRelease files for the full configs. This section documents
the design decisions and tradeoffs.

### DaemonSet — Kubernetes Pod Logs

Deployed via `role: Agent` (DaemonSet). One pod per node, scrapes pod
logs from all namespaces.

**Source tuning:**

| Setting | Value | Why |
|---|---|---|
| `read_from` | `end` | Prevents replaying entire log files on restart (see Rollout Notes §5). New files start tailing from the current end. |

**Transform (VRL):** Flattens Kubernetes metadata into top-level labels
(`namespace`, `pod`, `container`, `node`), then attempts `parse_json` on
`.message`. If the message is valid JSON, the parsed fields are merged
into the event (avoiding double-encoded JSON). Normalizes `.msg` → `.message`
for apps that use the non-standard key.

**Sink tuning (Loki):**

| Setting | Value | Why |
|---|---|---|
| `buffer.type` | `memory` | Disk buffers replay stale data on restart → OOM cascade. Memory buffer drops cleanly. |
| `buffer.max_events` | `5000` | Caps in-memory queue. At ~1 KB/event, this is ~5 MB. |
| `buffer.when_full` | `drop_newest` | Sheds load under backpressure instead of blocking the source. |
| `request.concurrency` | `2` | Prevents adaptive concurrency from opening too many in-flight requests during 429 storms. |
| `request.rate_limit_num` | `10` | 10 requests/second to Loki — well above steady-state needs, low enough to avoid overwhelming a single Loki pod. |
| `request.retry_max_duration_secs` | `30` | Caps retry backoff so a stuck batch is dropped after 30s instead of buffered indefinitely. |
| `batch.max_bytes` | `524288` | 512 KB batches — balances throughput with memory per in-flight request. |
| `out_of_order_action` | `accept` | Don't reject out-of-order entries; let Loki handle deduplication. |

**Tradeoff — `read_from: end`:** On restart (OOM, upgrade, node drain),
Vector skips any logs written while it was down. Checkpoints on the
hostPath (`/var/lib/vector`) track position in files Vector has already
seen, so only truly new/unknown files start from the end. This means:
- Normal operation: no data loss (checkpoints track position)
- After a crash: brief gap for logs written during the ~2s restart window
- After wiping checkpoints: all existing log content is skipped, only new
  writes are captured

**Tradeoff — memory buffer:** During Loki downtime or sustained 429s,
logs beyond the 5000-event buffer are dropped. For a homelab, this is
preferable to the alternative (disk buffer → stale replay → OOM cascade →
permanent crash loop). If durable delivery matters, the solution is
Loki scaling (more replicas or higher rate limits), not bigger buffers.

**Memory sizing (measured 2026-05-07):**

| Node | Pods | Steady-state RSS |
|---|---|---|
| aurinax | 15 | 634 Mi |
| miirym | 30 | 666 Mi |
| palarandusk | 41 | 1215 Mi |

Limit set to 2 Gi. Request set to 256 Mi. The high limit is deliberate —
the DaemonSet applies a uniform limit across all nodes, so it must
accommodate the busiest node (palarandusk).

### Deployment — Syslog Listener

Deployed via `role: Stateless-Aggregator` (Deployment, 1 replica).
LoadBalancer on 192.168.5.24:514 (UDP).

**Key differences from the Agent:**
- **Disk buffer is safe here.** Syslog is push-based — there's no file
  backlog to replay on restart. A disk buffer means syslog events survive
  Vector restarts and are delivered to Loki when it comes back.
- **Low volume.** Two sources (UDM + TrueNAS) producing a few hundred
  events/minute. Memory usage is ~26 Mi steady-state. 256 Mi limit is
  generous.
- **CEF parsing.** UniFi UDM sends syslog in CEF format with the
  timestamp in the hostname field. VRL extracts the real device name from
  `UNIFIdeviceName=` in the CEF payload.

---

## Grafana Integration

### New Datasource

Add to the existing Grafana HelmRelease `datasources.yaml`:

```yaml
- name: Loki
  type: loki
  url: http://loki-gateway.o11y.svc.cluster.local
  access: proxy
  jsonData:
    maxLines: 1000
```

### Dashboards (as deployed)

Added to Grafana HelmRelease under a `logs` folder provider:

| Dashboard | gnetId | Notes |
|---|---|---|
| Logging Dashboard via Loki v3 | 24574 | Replaced 12019 (broken with Loki 3.x legacy matchers) |
| Loki Metrics Dashboard | 17781 | Ingestion rate, chunk stats — requires Prometheus scraping Loki |
| Vector | 17045 | Agent/aggregator throughput, errors — requires PodMonitor |

---

## Garage Configuration

### Deployment

1 replica with replication factor 1. ZFS on TrueNAS provides the
underlying data redundancy via RAIDZ. Each replica uses ~50 MB RAM.
Data stored on iSCSI PVCs (50 Gi data, 1 Gi meta) provisioned by
democratic-csi.

### S3 Buckets

Pre-create via Garage CLI or init job:

| Bucket | Purpose |
|---|---|
| `loki-chunks` | Log chunk data |
| `loki-ruler` | Ruler configuration (if used) |

### Credentials

Generate an S3 access key pair in Garage, store as a SOPS-encrypted Secret
referenced by both Garage (for the key binding) and Loki (for the S3 client).

---

## Namespace & Directory Layout

All logging components live in the existing `o11y` namespace alongside
Prometheus and Grafana. Garage gets a new `storage` namespace.

```
kubernetes/apps/
├── o11y/
│   ├── loki/
│   │   ├── ks.yaml                       # dependsOn: garage; substituteFrom: cluster-secrets
│   │   └── app/
│   │       ├── kustomization.yaml
│   │       ├── helmrelease.yaml
│   │       └── ocirepository.yaml
│   ├── vector/
│   │   ├── ks.yaml                       # dependsOn: loki
│   │   └── app/
│   │       ├── kustomization.yaml
│   │       ├── helmrelease.yaml          # DaemonSet (Agent) for pod logs
│   │       └── ocirepository.yaml
│   ├── vector-syslog/
│   │   ├── ks.yaml                       # dependsOn: loki
│   │   └── app/
│   │       ├── kustomization.yaml
│   │       ├── helmrelease.yaml          # Deployment (Aggregator) + LoadBalancer
│   │       └── ocirepository.yaml
│   └── ... (existing: grafana, prometheus, etc.)
├── storage/
│   ├── namespace.yaml
│   ├── kustomization.yaml                # includes components/sops for cluster-secrets
│   ├── garage/
│   │   ├── ks.yaml                       # substituteFrom: cluster-secrets
│   │   └── app/
│   │       ├── kustomization.yaml
│   │       ├── helmrelease.yaml
│   │       └── helmrepository.yaml
│   └── ... (future: other storage services)
└── components/sops/
    └── cluster-secrets.sops.yaml         # all Garage + Loki S3 credentials
```

---

## Resource Budget (measured 2026-05-07)

| Component | Instances | Steady-state RSS | Memory limit | CPU request |
|---|---|---|---|---|
| Loki (single binary) | 1 | ~500 Mi | 1 Gi | 100m |
| Loki gateway | 1 | ~32 Mi | (chart default) | (chart default) |
| Vector Agent (DaemonSet) | 3 | 634–1215 Mi (varies by pod count on node) | 2 Gi × 3 | 25m × 3 |
| Vector syslog (Deployment) | 1 | ~26 Mi | 256 Mi | 25m |
| Garage | 1 | ~64 Mi | 256 Mi | 50m |
| **Worst-case total** | | | **~7.5 Gi** | **~250m** |

The worst-case total (all pods at limit) is ~7.8% of the cluster's 96 GB.
Measured steady-state is closer to ~3.2 Gi (~3.3%). The Vector Agent
dominates — its memory is proportional to pod count per node, not log
volume. See the Vector Configuration section for per-node measurements.

---

## Dependency Chain (Flux Kustomization order)

```
garage (storage namespace)
  └── loki (o11y, dependsOn: garage)
        ├── vector (o11y, dependsOn: loki)
        └── vector-syslog (o11y, dependsOn: loki)
              └── grafana update (already deployed, just add datasource)
```

Grafana doesn't need to re-deploy — just update its HelmRelease values to
add the Loki datasource. Grafana already has `dependsOn: kube-prometheus-stack`,
and Loki is independent of the Prometheus stack.

---

## SOPS Secrets

All credentials are consolidated in the cluster-wide secret at
`kubernetes/components/sops/cluster-secrets.sops.yaml`. This secret is
replicated to every namespace via the `components/sops` Kustomization
component. Both the Garage and Loki Flux Kustomizations use
`postBuild.substituteFrom` to reference `cluster-secrets`.

### Variables added to `cluster-secrets`

| Variable | Format | Used by |
|---|---|---|
| `GARAGE_RPC_SECRET` | 64 hex chars (`openssl rand -hex 32`) | Garage inter-node RPC |
| `GARAGE_ADMIN_TOKEN` | 64 hex chars | Garage admin API |
| `GARAGE_S3_KEY_ID` | `GK` + 24 hex chars (`GK$(openssl rand -hex 12)`) | Garage key binding |
| `GARAGE_S3_SECRET_KEY` | 64 hex chars | Garage key binding |
| `LOKI_S3_KEY_ID` | Same value as `GARAGE_S3_KEY_ID` | Loki S3 storage config |
| `LOKI_S3_SECRET_KEY` | Same value as `GARAGE_S3_SECRET_KEY` | Loki S3 storage config |

To rotate: decrypt `cluster-secrets.sops.yaml`, update the values,
re-encrypt, commit. Both Garage and Loki will pick up the new values
on the next Flux reconciliation.

---

## Manual Steps (post-deploy)

1. **Create SOPS secrets** — generate credentials using the script above,
   create the two `secret.sops.yaml` files, encrypt with age, commit
2. **Verify Garage** — `kubectl exec -n storage garage-0 -- garage status`
   should show the node connected and buckets created
3. **Verify Loki** — `kubectl logs -n o11y -l app.kubernetes.io/name=loki`
   should show successful S3 connection
4. **UDM syslog** — Settings → Logging → enable Remote Syslog →
   `192.168.5.24:514` UDP
5. **TrueNAS syslog** — System → Advanced → Syslog → `192.168.5.24:514` UDP
6. **Verify in Grafana** — navigate to Explore, select the Loki datasource,
   query `{source="syslog"}` to confirm syslog ingestion, and
   `{source="kubernetes"}` to confirm pod log scraping

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| UDM doesn't forward firewall logs via standard syslog | Missing firewall events in Loki | Upgrade to UniFi Network App v9.3+ for CEF export, or accept partial coverage |
| Garage data loss (iSCSI PVC failure) | All logs lost | Logs are operational data, not critical. 30-day retention is for debugging, not compliance. ZFS snapshots on the backing zvol provide point-in-time recovery. |
| Loki single binary OOM | Log ingestion stops | Set memory limit to 1 GB, monitor via Prometheus `container_memory_working_set_bytes`. Scale to 2 GB if needed — the nodes have headroom. |
| Vector syslog listener pod restart | Brief syslog gap (UDP has no retry) | Vector restarts in seconds. UDP syslog is inherently lossy. Acceptable for homelab. |
| Garage AGPL license | Legal concern if distributing | Internal use only, not distributed. AGPL is not a concern. |

---

## Rollout Notes (2026-05-06)

Deployed the full stack in one PR. Several issues surfaced during rollout
that required iterative fixes pushed directly to `main`. This section
captures the problems, fixes, and tradeoffs made under pressure that
should be revisited with fresh eyes.

### Issues Encountered

#### 1. Helm Template Escaping

Vector's label syntax `{{ field }}` conflicts with Helm's Go template
engine. The CI `helm template` check failed because Helm tried to evaluate
`{{ namespace }}` as a Go template variable.

**Fix:** Escape as `{{ "{{ field }}" }}` in all HelmRelease label blocks.
This is ugly but correct — Helm renders the outer `{{ }}`, leaving the
literal `{{ field }}` for Vector.

#### 2. Secret Management (Chicken-and-Egg)

Originally created per-app SOPS secrets (`garage-secret`, `loki-secret`)
referenced via `postBuild.substituteFrom` in the same Flux Kustomization
that deployed them. Flux can't substitute from a secret that doesn't exist
yet.

**Fix:** Consolidated all credentials into `cluster-secrets` (already
replicated to all namespaces via the `components/sops` Kustomization
component). Deleted the per-app secret files.

**Note:** The "SOPS Secrets" section above still describes the old per-app
approach. The actual implementation uses `cluster-secrets`.

#### 3. Garage S3 Bucket Permissions (403s)

Loki got 403 Forbidden from Garage. The Garage Helm chart has two places
that look like they control bucket permissions:
- `clusterConfig.buckets[].keys[]` — **informational only**, does nothing
- `clusterConfig.keys.<name>.buckets[]` — **actually grants permissions**

**Fix:** Moved permission grants to `clusterConfig.keys.loki.buckets[]`
with explicit `read: true, write: true` for each bucket.

#### 4. Vector OOM Cycle (the big one)

This was a cascading failure that took multiple iterations to resolve:

1. **Initial burst:** Vector read every pod log file from byte 0, sending
   days of historical logs to Loki simultaneously across all 3 nodes.
2. **Loki rejects:** Loki hit rate limits (429 Too Many Requests) and
   rejected old entries beyond its acceptance window (400 Bad Request
   "entry too far behind").
3. **Retry storm:** Vector retried 429s with exponential backoff, buffering
   all pending data in memory while waiting.
4. **OOMKill:** Memory exceeded the 256Mi limit → OOMKilled → pod restarts
   → Vector loses its checkpoint → reads from byte 0 again → cycle repeats.

**Fixes applied (in order):**

| Fix | What | Why |
|---|---|---|
| Raise Loki rate limits | `ingestion_rate_mb: 16`, `per_stream_rate_limit: 5MB` | Single-tenant homelab doesn't need conservative multi-tenant defaults |
| Disk-backed buffers | `buffer.type: disk`, `max_size: 268435488` (256 MB), `when_full: drop_newest` | Spills to disk instead of RAM; drops newest entries under pressure rather than OOMing |
| Increase Vector memory limit | 256Mi → 1Gi | Headroom for VRL transforms and in-flight batches |
| `ignore_older_secs: 600` | Skip log files not modified in 10 minutes | Didn't actually help — see below |
| `read_from: end` | Start reading new/unknown files from the tail | **This was the real fix** — prevents replaying old entries on restart |
| `reject_old_samples_max_age: 168h` | Loki accepts entries up to 7 days old | Wider window so late-arriving entries get a clean 400 instead of retry storms |

**Why `ignore_older_secs` didn't work:** It controls which *files* Vector
opens, not which *lines* it reads. Pod log files are still actively written
to (they contain both old and new lines), so Vector opens them and reads
from the beginning regardless of the setting.

---

### Active Tradeoffs (updated 2026-05-07)

These are deliberate compromises in the current configuration. Each is
documented here so the rationale is preserved.

#### `read_from: end` — Brief Log Gaps on Restart

With `read_from: end`, when Vector discovers a file it hasn't seen before
(no checkpoint), it starts reading from the current end instead of the
beginning. This prevents the OOM cascade described in §5 above. The
tradeoff:

- **Normal operation:** No data loss. Vector tracks file positions via
  checkpoints on the hostPath (`/var/lib/vector`). Known files resume
  from where they left off.
- **After a crash:** The ~2s restart window may miss a few log lines.
  Acceptable for a homelab.
- **After checkpoint wipe:** All existing log content is skipped. Only new
  writes from that point forward are captured. This is a deliberate
  break-glass action — checkpoints should only be wiped when Vector is
  stuck in a crash loop.

**Why not switch back to `read_from: beginning`:** We tried this. Even
with disk buffers, the combination of stale checkpoint replay + 429 retries
+ adaptive concurrency consistently OOMed pods on nodes with 30+ pods.
The `kubernetes_logs` source uses ~15–30 MB per pod just for metadata and
file readers — there isn't enough memory headroom for large replay buffers.
Keep `read_from: end` until Vector improves memory efficiency for this
source.

#### Memory Buffer (Agent) vs. Disk Buffer (Syslog)

The Agent uses `buffer.type: memory` while syslog uses `buffer.type: disk`.
This is intentional, not an oversight:

| | Agent (DaemonSet) | Syslog (Deployment) |
|---|---|---|
| **Source type** | File-based (reads pod logs) | Push-based (receives UDP) |
| **Replay risk** | High — disk buffer replays stale log data on restart, causing OOM | None — syslog doesn't replay |
| **Data loss on restart** | Logs continue being written to files; Vector catches up via checkpoints | UDP datagrams sent during downtime are lost regardless of buffer type |
| **Buffer choice** | Memory (5000 events, ~5 MB) — drops cleanly under pressure | Disk (256 MB) — survives restarts, replays to Loki |

#### Loki Rate Limits Are Generous

Current limits (`ingestion_rate_mb: 16`, `per_stream_rate_limit: 5MB`)
are well above steady-state needs. They were raised to handle the initial
backfill flood and are kept high because:
- Single-tenant homelab — there's no noisy-neighbor risk to protect against
- Tight limits cause 429s → Vector retries → memory pressure → OOM
- The downside of high limits (Loki using more memory) is bounded by the
  1 Gi memory limit on the Loki pod

**To revisit:** After a month of steady-state, check
`loki_distributor_bytes_received_total` in Prometheus. If sustained
ingestion is well under 1 MB/s, consider tightening to catch runaway log
producers (e.g., a debug-logging app).

### Continued Troubleshooting (2026-05-07)

The OOM crash loop persisted after the initial fixes from 2026-05-06.
Further investigation revealed two compounding issues.

#### 10. Stale Checkpoint Replay

The `read_from: end` setting only applies to files **without** a checkpoint.
Files that Vector has previously seen resume from their checkpoint position
(stored on the hostPath at `/var/lib/vector`). After adding `read_from: end`,
the existing checkpoint data from before the fix was still on the host
filesystem, so Vector continued replaying from old positions.

**Fix:** Deployed busybox pods to each node to `rm -rf /var/lib/vector/*`,
then restarted the DaemonSet. This gave Vector a clean start where all
files are treated as "new" and start from the end.

**Operational note:** If Vector gets stuck in a crash loop in the future,
the recovery procedure is:
1. Scale the DaemonSet to 0 (or delete the crashing pod)
2. Run a cleanup pod on the affected node to wipe `/var/lib/vector/*`
3. Restart the DaemonSet
4. Accept that existing log content is skipped (only new writes captured)

#### 11. Disk Buffer Replay Cascade

Even after clearing checkpoints, OOMs continued. The disk buffer
(`buffer.type: disk`) was the culprit: on each crash, Vector wrote
pending events to the disk buffer. On restart, it replayed the buffer
contents AND read new log files simultaneously, spiking memory. The
replay itself could trigger 429s, which caused more buffering, creating
a self-reinforcing OOM loop.

**Fix:** Switched the Agent's Loki sink to `buffer.type: memory` with
`max_events: 5000` and `when_full: drop_newest`. This means:
- No stale data to replay on restart
- Memory usage for the buffer is bounded (~5 MB for 5000 events)
- Under Loki backpressure, new events are dropped instead of queued

The syslog Deployment keeps `buffer.type: disk` because it's push-based
and doesn't have the replay problem.

#### 12. Vector Memory Scales with Pod Count

With disk buffer and checkpoint issues resolved, Vector pods finally
stabilized but at much higher memory than expected. Measured steady-state:
- aurinax (15 pods): 634 Mi
- miirym (30 pods): 666 Mi
- palarandusk (41 pods): 1215 Mi

This is ~15–30 MB per pod on the node. The `kubernetes_logs` source
maintains a Kubernetes API watch, per-pod metadata, and a file reader
per active container log file. Vector's advertised "30–50 MB" footprint
is for the bare process without the k8s source.

Memory limit raised from 512 Mi → 2 Gi to accommodate the busiest node
with headroom. Request raised from 128 Mi → 256 Mi.

---

## Future Enhancements

| Enhancement | When |
|---|---|
| Loki alerting rules (ruler) → Alertmanager → Discord | After initial deployment is stable |
| Log-based Grafana dashboards (firewall events, NAS health) | After confirming log labels/structure |
| Distributed tracing with Tempo | When ready to learn tracing (see below) |
| Garage for Volsync/Kopia backend (replace NFS repo) | If S3-backed Kopia repos prove more reliable |
| Retention tiers (7d hot, 30d cold) | If storage becomes a concern |

### Tracing Roadmap

Vector can act as a basic OTLP trace forwarder today, but full tracing
requires additional components. The planned progression:

1. **Deploy Tempo** (Grafana's trace backend) — single binary mode, backed
   by Garage S3, same pattern as Loki. Add as a Grafana datasource.
2. **Add Vector OTLP source** — Vector's `opentelemetry` source receives
   OTLP traces over gRPC/HTTP and forwards via the `opentelemetry` sink
   to Tempo. This gives basic trace forwarding with no new agents.
3. **Instrument apps** — add OpenTelemetry SDKs to applications, point
   them at Vector's OTLP endpoint.
4. **Graduate to OTel Collector** — if you need tail sampling, span
   processors, or advanced trace routing, deploy the OTel Collector as
   a dedicated DaemonSet alongside Vector. Vector keeps doing logs,
   OTel Collector handles traces. They're complementary, not competing.

| Component | Role | When |
|---|---|---|
| Tempo | Trace storage + query backend | Phase 2 |
| Vector `opentelemetry` source | Basic OTLP trace receiver + forwarder | Phase 2 |
| OTel Collector | Advanced trace processing (tail sampling, connectors) | Phase 3 (if needed) |
