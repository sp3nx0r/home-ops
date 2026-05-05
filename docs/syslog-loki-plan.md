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
| Memory footprint | ~100 MB | **~30–50 MB** |
| Config language | Alloy/River (Grafana-specific) | **TOML** (standard) |
| Transform engine | `loki.process` stages | **VRL** (full expression language) |
| Vendor lock-in | Grafana ecosystem | **Vendor-neutral**, any sink |
| Trace support | Native OTLP | OTLP source + sink (passthrough) |
| License | Apache 2.0 | MPL 2.0 |

Key advantages:
- **VRL (Vector Remap Language)** — a proper programming language for log
  transforms, far more powerful than Alloy's pipeline stages for parsing,
  enriching, and routing
- **Lower memory** — ~30–50 MB per instance vs ~100 MB
- **Career alignment** — used at work, homelab builds hands-on expertise
- **Future trace support** — Vector can receive OTLP traces and forward to
  Tempo, acting as a basic trace pipeline until OTel Collector is needed

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

### Helm Values (reference)

```yaml
loki:
  auth_enabled: false
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: s3
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  ingester:
    chunk_encoding: snappy
  querier:
    max_concurrent: 2
  pattern_ingester:
    enabled: true
  limits_config:
    allow_structured_metadata: true
    volume_enabled: true
    retention_period: 720h  # 30 days
  compactor:
    retention_enabled: true
    delete_request_store: s3
  storage:
    type: s3
    bucketNames:
      chunks: loki-chunks
      ruler: loki-ruler
    s3:
      endpoint: garage.storage.svc.cluster.local:3900
      region: garage
      accessKeyId: ${GARAGE_ACCESS_KEY}
      secretAccessKey: ${GARAGE_SECRET_KEY}
      s3ForcePathStyle: true
      insecure: true
  commonConfig:
    replication_factor: 1

deploymentMode: SingleBinary

singleBinary:
  replicas: 1
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi

gateway:
  enabled: true

minio:
  enabled: false

lokiCanary:
  enabled: false
```

---

## Vector Configuration

### DaemonSet — Kubernetes Pod Logs

Deployed via the Vector Helm chart with `role: Agent` (DaemonSet). Scrapes
pod logs from all namespaces and forwards to Loki.

```toml
[sources.kubernetes_logs]
type = "kubernetes_logs"

[transforms.kube_parse]
type = "remap"
inputs = ["kubernetes_logs"]
source = '''
.namespace = .kubernetes.pod_namespace
.pod = .kubernetes.pod_name
.container = .kubernetes.container_name
.node = .kubernetes.pod_node_name
del(.kubernetes)
del(.file)
'''

[sinks.loki]
type = "loki"
inputs = ["kube_parse"]
endpoint = "http://loki-gateway.o11y.svc.cluster.local"
encoding.codec = "json"

[sinks.loki.labels]
namespace = "{{ namespace }}"
pod = "{{ pod }}"
container = "{{ container }}"
node = "{{ node }}"
source = "kubernetes"
```

### Deployment — Syslog Listener

Separate Vector instance (`role: Stateless-Aggregator`, Deployment) with a
LoadBalancer service on 192.168.5.24:514.

```toml
[sources.syslog]
type = "syslog"
address = "0.0.0.0:5140"    # high port, service maps 514 → 5140
mode = "udp"

[transforms.syslog_parse]
type = "remap"
inputs = ["syslog"]
source = '''
.host = del(.hostname)
.severity = del(.severity)
.facility = del(.facility)
.app = del(.appname)
del(.procid)
del(.msgid)
del(.version)
'''

[sinks.loki]
type = "loki"
inputs = ["syslog_parse"]
endpoint = "http://loki-gateway.o11y.svc.cluster.local"
encoding.codec = "json"

[sinks.loki.labels]
host = "{{ host }}"
severity = "{{ severity }}"
facility = "{{ facility }}"
app = "{{ app }}"
source = "syslog"
```

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

### Dashboard Recommendations

| Dashboard | gnetId | Description |
|---|---|---|
| Loki & Promtail | 10880 | Log volume, ingestion rate, error rates |
| Loki Dashboard quick search | 12019 | Fast log search interface |

These can be added to the Grafana HelmRelease `dashboards` section under a
new `logs` folder provider.

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
│   │   ├── ks.yaml
│   │   └── app/
│   │       ├── kustomization.yaml
│   │       ├── helmrelease.yaml
│   │       ├── ocirepository.yaml
│   │       └── secret.sops.yaml          # Garage S3 credentials
│   ├── vector/
│   │   ├── ks.yaml
│   │   └── app/
│   │       ├── kustomization.yaml
│   │       ├── helmrelease.yaml          # DaemonSet (Agent) for pod logs
│   │       └── ocirepository.yaml
│   ├── vector-syslog/
│   │   ├── ks.yaml
│   │   └── app/
│   │       ├── kustomization.yaml
│   │       ├── helmrelease.yaml          # Deployment (Aggregator) + LoadBalancer
│   │       └── ocirepository.yaml
│   └── ... (existing: grafana, prometheus, etc.)
└── storage/
    ├── namespace.yaml
    ├── kustomization.yaml
    ├── garage/
    │   ├── ks.yaml
    │   └── app/
    │       ├── kustomization.yaml
    │       ├── helmrelease.yaml
    │       ├── helmrepository.yaml
    │       └── secret.sops.yaml          # Garage admin + S3 keys
    └── ... (future: other storage services)
```

---

## Resource Budget

| Component | Instances | RAM (per) | RAM (total) | CPU (request) |
|---|---|---|---|---|
| Loki (single binary) | 1 | 256 MB–1 GB | ~1 GB | 100m |
| Loki gateway | 1 | ~32 MB | ~32 MB | (chart default) |
| Vector DaemonSet (Agent) | 3 (one per node) | ~64 MB | ~192 MB | 25m × 3 |
| Vector syslog Deployment (Aggregator) | 1 | ~64 MB | ~64 MB | 25m |
| Garage | 1 | ~64 MB | ~64 MB | 50m |
| **Total** | | | **~1.35 GB** | **~250m** |

Against the cluster's 96 GB total RAM (3 × 32 GB), this is ~1.4% utilization
for the entire logging stack.

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

## SOPS Secrets (must be created manually)

Two SOPS-encrypted secrets are required before deployment. Generate the
credentials, then encrypt with `sops --encrypt --age <your-public-key>`.

### 1. Garage Secret — `kubernetes/apps/storage/garage/app/secret.sops.yaml`

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: garage-secret
stringData:
  # 32-byte hex string for inter-node RPC authentication
  GARAGE_RPC_SECRET: "<openssl rand -hex 32>"
  # admin API bearer token
  GARAGE_ADMIN_TOKEN: "<openssl rand -hex 32>"
  # S3 key ID: must start with 'GK' + 24 hex chars (12 bytes)
  GARAGE_S3_KEY_ID: "GK<openssl rand -hex 12>"
  # S3 secret key: 64 hex chars (32 bytes)
  GARAGE_S3_SECRET_KEY: "<openssl rand -hex 32>"
```

### 2. Loki Secret — `kubernetes/apps/o11y/loki/app/secret.sops.yaml`

Must contain the **same S3 key pair** as the Garage secret above.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: loki-secret
stringData:
  LOKI_S3_KEY_ID: "<same GK... value as GARAGE_S3_KEY_ID>"
  LOKI_S3_SECRET_KEY: "<same value as GARAGE_S3_SECRET_KEY>"
```

### Quick generation script

```bash
RPC=$(openssl rand -hex 32)
ADMIN=$(openssl rand -hex 32)
KEY_ID="GK$(openssl rand -hex 12)"
SECRET_KEY=$(openssl rand -hex 32)

echo "GARAGE_RPC_SECRET: $RPC"
echo "GARAGE_ADMIN_TOKEN: $ADMIN"
echo "GARAGE_S3_KEY_ID: $KEY_ID"
echo "GARAGE_S3_SECRET_KEY: $SECRET_KEY"
echo "LOKI_S3_KEY_ID: $KEY_ID"
echo "LOKI_S3_SECRET_KEY: $SECRET_KEY"
```

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
