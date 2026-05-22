# Zeroscaler — NFS-Aware Scale-to-Zero for the Cluster

> Status: Planned
> Priority: High (directly addresses NFS failure resilience for backups and media stack)

## Problem

12 apps mount NFS from TrueNAS (`192.168.5.40`). When NFS becomes
unavailable — NAS reboot, network blip, ZFS scrub stall — these pods
hang on stale mounts and enter CrashLoopBackOff. Kopia is the worst
case: a stuck Kopia pod with a stale NFS mount can block VolSync backup
jobs cluster-wide.

There is no mechanism today to gracefully scale these workloads down
when NFS is unhealthy.

## Solution

Adopt onedr0p's "zeroscaler" pattern: an HPA per app that scales between
0 and 1 replicas based on an external Prometheus metric for NFS health.

```
┌─────────────────┐    scrapes    ┌────────────────────┐
│ Blackbox Exporter├──────────────┤ Prometheus          │
│ (TCP 2049 probe) │              │ probe_success metric│
└─────────────────┘              └────────┬───────────┘
                                          │
                                 exposes as│external metric
                                          │
                               ┌──────────▼──────────┐
                               │ prometheus-adapter    │
                               │ (k8s metrics API)    │
                               └──────────┬──────────┘
                                          │
                                    reads │metric
                                          │
                               ┌──────────▼──────────┐
                               │ HPA (per app)        │
                               │ min: 0, max: 1       │
                               │ target: value "1"    │
                               └──────────┬──────────┘
                                          │
                              NFS healthy? │ scale to 1
                              NFS down?    │ scale to 0
                                          ▼
                               ┌─────────────────────┐
                               │ App Deployment       │
                               └─────────────────────┘
```

When `probe_success{job="nfs_probe"} == 1`, the HPA keeps the app at 1
replica. When the probe fails (value 0), the HPA scales to 0 — no
crashloops, no stuck mounts, no wasted resources.

## Reference: onedr0p/home-ops

onedr0p implements this as three pieces:

1. **Blackbox Exporter** with a `Probe` CR (`lan-nfs`) checking
   `expanse.internal:2049` via `tcp_connect` module
2. **prometheus-adapter** with an external metric rule exposing
   `probe_success` to the Kubernetes metrics API
3. **Kustomize Component** (`kubernetes/components/zeroscaler/`) containing
   a templated HPA that apps opt into

19 apps use the component. Kopia and the entire media stack are covered.
Two IoT apps (zigbee, zwave) override the job label to probe a different
device instead of NFS.

## Implementation

### Phase 1 — NFS Probe + Metric Pipeline

#### 1a. Deploy Blackbox Exporter

Create `kubernetes/apps/o11y/blackbox-exporter/` with app-template.

The deployment itself is minimal — the key piece is a Prometheus
Operator `Probe` CR:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Probe
metadata:
  name: nfs-probe
spec:
  jobName: nfs_probe
  module: tcp_connect
  prober:
    url: blackbox-exporter.o11y.svc.cluster.local:9115
  targets:
    staticConfig:
      static:
        - 192.168.5.40:2049
```

This produces `probe_success{job="nfs_probe"}` in Prometheus — 1 when
TCP 2049 is reachable, 0 when it isn't.

**Alternative considered:** Use an existing metric from `truenas-exporter`.
Rejected because `truenas-exporter` connects via WebSocket to the
TrueNAS API — if TrueNAS is up but NFS specifically is down (e.g.
service stopped, firewall issue), the exporter wouldn't catch it. A
direct TCP probe to port 2049 is the most accurate signal.

#### 1b. Configure prometheus-adapter

Add external metric rules to the existing `prometheus-adapter`
HelmRelease:

```yaml
values:
  prometheus:
    url: http://kube-prometheus-stack-prometheus.o11y.svc.cluster.local
    port: 9090
  rules:
    default: false
    external:
      - seriesQuery: '{__name__="probe_success"}'
        resources:
          namespaced: false
        name:
          as: probe_success
        metricsQuery: max_over_time(<<.Series>>{<<.LabelMatchers>>}[1m])
```

The `max_over_time(...[1m])` smooths out single-scrape blips so one
missed probe doesn't trigger a scale-down.

**Verify** with:
```bash
kubectl get --raw "/apis/external.metrics.k8s.io/v1beta1/namespaces/*/probe_success?labelSelector=job%3Dnfs_probe"
```

### Phase 2 — Zeroscaler Component

#### 2a. Create the Kustomize Component

```
kubernetes/components/zeroscaler/
├── kustomization.yaml
└── horizontalpodautoscaler.yaml
```

`kustomization.yaml`:
```yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - ./horizontalpodautoscaler.yaml
```

`horizontalpodautoscaler.yaml`:
```yaml
---
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: ${APP}
spec:
  minReplicas: 0
  maxReplicas: 1
  scaleTargetRef:
    apiVersion: apps/v1
    kind: ${CONTROLLER:=Deployment}
    name: ${APP}
  metrics:
    - type: External
      external:
        metric:
          name: ${ZEROSCALER_METRIC_NAME:=probe_success}
          selector:
            matchLabels:
              job: ${ZEROSCALER_JOB_NAME:=nfs_probe}
        target:
          type: Value
          value: "1"
  behavior:
    scaleDown:
      policies:
        - type: Pods
          value: 1
          periodSeconds: 15
      selectPolicy: Max
      stabilizationWindowSeconds: 0
    scaleUp:
      policies:
        - type: Pods
          value: 1
          periodSeconds: 15
      selectPolicy: Max
      stabilizationWindowSeconds: 0
```

Variable substitution (via Flux `postBuild`):
- `${APP}` — already set by every app's `ks.yaml`
- `${CONTROLLER}` — defaults to `Deployment`, override for StatefulSets
- `${ZEROSCALER_METRIC_NAME}` — defaults to `probe_success`
- `${ZEROSCALER_JOB_NAME}` — defaults to `nfs_probe`, override for
  non-NFS health checks

### Phase 3 — Roll Out to Apps

Apps opt in by adding the component to their `app/kustomization.yaml`
(following our existing convention for volsync):

```yaml
components:
  - ../../../../components/volsync
  - ../../../../components/zeroscaler
```

#### Rollout order

**Wave 1 — Kopia (highest value, lowest risk)**
- `volsync-system/kopia` — the Kopia web UI. Scaling this to zero during
  NFS outages prevents it from holding a broken repository connection.
  VolSync mover pods are separate and unaffected.

**Wave 2 — Media apps with NFS mounts**
All of these mount NFS for media libraries or downloads:
- `media/plex`
- `media/sonarr`
- `media/radarr`
- `media/bazarr`
- `media/sabnzbd`
- `media/qbittorrent` (and `qbittorrent-gluetun`)
- `media/tautulli`
- `media/seasonpackerr`

**Wave 3 — Evaluate remaining apps**
Apps that use VolSync PVCs but don't directly mount NFS (prowlarr,
autobrr, brrpolice, seerr, etc.) are less affected by NFS outages.
Consider adding zeroscaler if their VolSync backup failures during NFS
downtime cause issues.

### Phase 4 — Alerting

Add a PrometheusRule so we know when apps are scaled down:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: zeroscaler
spec:
  groups:
    - name: zeroscaler
      rules:
        - alert: NfsProbeDown
          expr: probe_success{job="nfs_probe"} == 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "NFS probe to TrueNAS is failing"
            description: >-
              TCP probe to 192.168.5.40:2049 has been failing for 2+ minutes.
              NFS-dependent apps will be scaled to zero by zeroscaler HPAs.
        - alert: ZeroscalerAppDown
          expr: kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler=~".+"} == 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "{{ $labels.horizontalpodautoscaler }} scaled to zero"
            description: >-
              HPA {{ $labels.horizontalpodautoscaler }} in
              {{ $labels.namespace }} has desired replicas of 0 for 5+ minutes.
```

## Differences from onedr0p

| Aspect | onedr0p | Our cluster |
|---|---|---|
| Component wiring | `spec.components` in Flux `ks.yaml` | `components:` in app `kustomization.yaml` (our convention) |
| NAS target | `expanse.internal:2049` | `192.168.5.40:2049` |
| Blackbox exporter | `blackbox-exporter-lan` (separate LAN instance) | Single `blackbox-exporter` (we have no WAN probes yet) |
| Alerting | Not present in their repo | PrometheusRule for NFS down + app scaled to zero |
| IoT overrides | zigbee/zwave override `ZEROSCALER_JOB_NAME` | Not needed currently, but the variable is there if we add hardware probes later |

## Dependencies

- `prometheus-adapter` — already deployed, needs rule configuration
- `kube-prometheus-stack` — already deployed (Prometheus + ServiceMonitor CRDs)
- `blackbox-exporter` — **new deployment required**
- Prometheus Operator `Probe` CRD — included with kube-prometheus-stack

## Risks and Mitigations

| Risk | Mitigation |
|---|---|
| Flapping probe causes rapid scale up/down | `max_over_time(...[1m])` in prometheus-adapter smooths single blips; HPA behavior has `stabilizationWindowSeconds: 0` for fast recovery but the 1m metric window prevents false negatives |
| App scaled to zero loses in-flight work | Media apps are stateless request handlers (Sonarr/Radarr) or can resume (qBittorrent). Plex streams will drop but that's better than a hung pod. Kopia web UI is read-only. |
| HPA conflicts with manual replica count | HPA takes precedence over the Deployment's `spec.replicas`. This is standard Kubernetes behavior and the desired outcome. |
| Blackbox exporter itself goes down | Prometheus will report `probe_success` as absent (not 0), and `max_over_time` will use the last known value. If absent long enough, the HPA falls back to its last known state. Add an alert for blackbox exporter health. |

## Future Considerations

- **Multiple NFS targets:** If we add more NAS devices, create separate
  `Probe` CRs with different job labels and override
  `ZEROSCALER_JOB_NAME` per app.
- **Extend to non-NFS checks:** The component is generic enough to gate
  on any Prometheus metric (e.g., an upstream API health check). The
  variable defaults make NFS the zero-config path.
- **KEDA alternative:** KEDA can also do metric-driven 0-1 scaling. It's
  heavier than a plain HPA + prometheus-adapter but offers more features
  (cron scaling, multiple triggers). Not worth the complexity for our
  use case today.
