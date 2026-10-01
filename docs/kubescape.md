# Kubescape — posture and vulnerability management

Kubescape Operator runs in-cluster (no ARMO cloud account) to provide:

- **Posture scans** against named control frameworks: NSA/CISA hardening,
  MITRE ATT&CK, CIS Kubernetes v1.12 and Kubescape's `security` set.
- **Image CVE scanning** (Grype), filtered by **runtime relevancy**: CVEs in
  packages a container never loads are separated from the ones it does, and
  OpenVEX `not_affected` statements are generated for the unused ones.

Kubescape is used for evaluation only. Its runtime threat detection and
admission webhook stay off: runtime detection is planned for Tetragon (P1 in
`docs/sre-and-security-evaluation.md`) and admission enforcement for Kyverno
(PR #524). Neither is deployed yet, so the cluster currently has **no** runtime
detection and **no** admission enforcement. Network policy stays with the
hand-authored CNPs.

> **Status:** Implemented in `kubernetes/apps/kubescape/` (chart
> `kubescape-operator` 1.40.4). Post-merge verification steps are in
> [Verification](#verification).

## Layout

| Path                                                        | Purpose                                                                                                                                                                 |
| ----------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kubernetes/apps/kubescape/namespace.yaml`                  | `kubescape` namespace, PSA `enforce: privileged` (node-agent), `audit: baseline`.                                                                                       |
| `kubescape-operator/app/helmrelease.yaml`                   | Chart values: capabilities, schedules, sizing, digest-pinned images, post-render patches.                                                                               |
| `kubescape-operator/app/helmrepository.yaml`                | `https://kubescape.github.io/helm-charts/` — the chart is not published as OCI.                                                                                         |
| `kubescape-operator/app/ciliumnetworkpolicy.yaml`           | One CNP per component (the cluster default-deny floor covers this namespace).                                                                                           |
| `kubescape-operator/app/clusterrole.yaml`                   | `kubescape-results-view`, aggregated into `view` so Headlamp and `oidc:k8s_viewers` can read results.                                                                   |
| `kubescape-operator/app/prometheusrule.yaml`                | Operational-health alerts only (no alerts on findings).                                                                                                                 |
| `kubescape-operator/app/dashboards/kubescape-overview.json` | Grafana dashboard vendored from `kubescape/prometheus-exporter@369139f` (`dashboards/grafana_dashboard.json`), shipped as a sidecar ConfigMap in the `Security` folder. |
| `kubernetes/apps/o11y/headlamp/app/helmrelease.yaml`        | Adds the `headlamp_kubescape` plugin to `pluginsManager`.                                                                                                               |

## Components

| Component             | Kind       | Role                                                                                                   | Privileges                                                                |
| --------------------- | ---------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------- |
| `operator`            | Deployment | Orchestrates scans; triggered by the scheduler CronJobs on `:4002`.                                    | restricted-compliant                                                      |
| `kubescape`           | Deployment | Posture scanner (Rego/CEL controls over cluster objects + node host data).                             | restricted-compliant                                                      |
| `kubevuln`            | Deployment | Grype CVE matching over node-agent SBOMs; writes vulnerability manifests and VEX.                      | restricted-compliant                                                      |
| `storage`             | Deployment | Aggregated API server `v1beta1.spdx.softwarecomposition.kubescape.io`, SQLite on a PVC.                | restricted-compliant                                                      |
| `node-agent`          | DaemonSet  | eBPF sensor: SBOMs from container rootfs, runtime relevancy profiles, host sensing (kubelet/OS/ports). | **hostPID, hostPath `/`, SYS_ADMIN/SYS_PTRACE/NET_ADMIN/…, runs as root** |
| `prometheus-exporter` | Deployment | Converts scan summaries into `kubescape_*` metrics.                                                    | restricted-compliant                                                      |
| schedulers            | CronJobs   | Weekly HTTP POST to the operator.                                                                      | restricted-compliant                                                      |

The node-agent is the only reason the namespace is `privileged`. It has no
network access beyond the apiserver (see [Network policy](#network-policy)).

## Capability choices

| Capability                                                   | Setting | Why                                                                                                                                                        |
| ------------------------------------------------------------ | ------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `configurationScan`, `nodeScan`                              | on      | Framework posture scans; `nodeScan` uses the node-agent host sensor (the separate host-scanner DaemonSet no longer exists).                                |
| `continuousScan`                                             | on      | Also gates storing **detailed** `WorkloadConfigurationScan` objects. The watch set is emptied (`continuousScanning.matchingRules`) to avoid rescan floods. |
| `vulnerabilityScan`, `nodeSbomGeneration`                    | on      | SBOMs are built on the node, so kubevuln never pulls images and needs no registry egress or pull-secret access.                                            |
| `relevancy`, `runtimeObservability`                          | on      | The differentiator vs. Trivy: CVEs are split into "loaded at runtime" and "present but unused".                                                            |
| `vexGeneration`                                              | on      | Experimental. OpenVEX documents stored as `OpenVulnerabilityExchangeContainer`; advisory data only.                                                        |
| `prometheusExporter`                                         | on      | Metrics + dashboard. `kubescape.serviceMonitor` stays off: every scrape of the scanner triggers a scan.                                                    |
| `runtimeDetection`, `malwareDetection`, `httpDetection`      | off     | Runtime detection is planned for Tetragon (not yet deployed).                                                                                              |
| `admissionController`                                        | off     | Detection-only webhook; enforcement is planned for Kyverno (PR #524, not yet merged).                                                                      |
| `networkPolicyService`                                       | off     | Emits vanilla NetworkPolicy (not CNP) and is the main storage CPU cost (~600m observed elsewhere).                                                         |
| `seccompProfileService`                                      | off     | No path to ship generated profiles to Talos nodes.                                                                                                         |
| `riskAcceptance`                                             | off     | No Git-managed `SecurityException`s yet; see [Expected Talos noise](#expected-talos-cis-noise).                                                            |
| `autoUpgrading`, `remediation`, `manageWorkloads`, ARMO sync | off     | Flux owns upgrades; no mutating RBAC; no cloud backend.                                                                                                    |

Other hardening:

- `global.enableClusterWideSecretAccess: false` — the scanner and operator do
  not get cluster-wide Secret read.
- `kubescape.skipUpdateCheck: true`.
- `certificates.strategy: initContainer` — storage mTLS certs are generated at
  runtime and the CA Secret is reused, so Flux upgrades don't rotate them.
- `keepLocal: true` in the scheduler request body (results never leave the
  cluster; `clusterData.keepLocal` is also `true` without a `server`).
- All images are pinned `tag@sha256` (index digests) so Renovate's helm-values
  manager can bump them. Keep them aligned with the chart version — the chart
  bundles CRDs and config that the operands depend on.

### Scope and schedules

- `excludeNamespaces: kubescape,kube-public,kube-node-lease` — `kube-system`
  **is** scanned (the chart excludes it by default). The `kubescape` namespace
  itself is not scanned.
- Frameworks: `nsa`, `mitre`, `cis-v1.12.0`, `security` (weekly scan and
  `defaultFrameworks` for the startup scan).
- Posture `0 5 * * 0`, vulnerabilities `0 1 * * 0` (Sundays, UTC). They are
  weekly because storage's SQLite database sits on the HDD-backed iSCSI pool,
  and sync-heavy load there slows every other zvol. They are staggered because
  both write heavily to storage's single-writer SQLite database.

## Viewing results

- **Headlamp** (`headlamp.${SECRET_DOMAIN}`): the Kubescape plugin adds
  Compliance and Vulnerabilities views (per control, namespace, workload, image,
  CVE). Access comes from `kubescape-results-view`, aggregated into `view`.
  It deliberately omits `containerprofiles` (runtime profiles record the argv
  and environment of every exec'd process), so the plugin's runtime-profile
  views are empty for viewers and need an admin identity.
  Custom frameworks and exceptions created in the plugin are stored as
  ConfigMaps in `kubescape` and need an admin identity.
- **Grafana** → `Security` → _Kubescape Vulnerabilities Overview_: control and
  CVE counts by severity at cluster, namespace and workload level
  (`kubescape_controls_total_*`, `kubescape_vulnerabilities_{total,relevant}_*`).
  The exporter ServiceMonitor is post-rendered with `honorLabels: true` so the
  exporter's own `namespace`/`workload` labels are kept.
- **kubectl**:

    ```sh
    kubectl get workloadconfigurationscansummaries -A
    kubectl get vulnerabilitymanifestsummaries -A
    kubectl get vulnerabilitymanifests -n kubescape -l kubescape.io/context=filtered   # relevancy-filtered
    kubectl get openvulnerabilityexchangecontainers -A
    kubectl get kubeletinfos,openportslists,linuxsecurityhardeningstatuses   # node host data
    ```

No findings are alerted on; alerts cover operational health only.

## Network policy

Every component has its own CNP. All of them allow DNS (L7) and the
kube-apiserver on `:6443`. Component-specific rules:

| Component           | Ingress                                         | Extra egress                                                                                          |
| ------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| operator            | schedulers → `:4002`; host probes `:8000`       | kubescape + kubevuln `:8080`                                                                          |
| kubescape (scanner) | operator → `:8080`; host probes                 | `github.com`, `release-assets.githubusercontent.com`, `tuf-repo-cdn.sigstore.dev` (`toFQDNs`, `:443`) |
| kubevuln            | operator → `:8080`; host probes                 | `grype.anchore.io` (`toFQDNs`, `:443`)                                                                |
| storage             | `kube-apiserver`/`host`/`remote-node` → `:8443` | —                                                                                                     |
| node-agent          | host probes `:7888`                             | —                                                                                                     |
| prometheus-exporter | Prometheus → `:8080`; host probes               | —                                                                                                     |
| schedulers          | none                                            | operator `:4002`                                                                                      |

Notes on the FQDN rules:

- The control library is downloaded on every scan from
  `github.com/kubescape/regolibrary/releases/latest/download/…`, which
  redirects to `release-assets.githubusercontent.com`. The scanner's current
  regolibrary (v2.0.1) does not verify signatures; newer versions verify the
  checksums file against the Sigstore trusted root fetched over TUF, hence
  `tuf-repo-cdn.sigstore.dev`.
- kubevuln uses Grype v6: both the DB listing and the ~180 MB archive come
  from `grype.anchore.io`. `toolbox-data.anchore.io` is the legacy v5 host and
  is not needed. The DB is cached on a PVC (`grypeDbPersistence`).
- `kubescape` and `kubevuln` are post-rendered with `ndots: 1`, because CoreDNS
  autopath otherwise defeats `toFQDNs` (see
  [the default-deny floor runbook](./cluster-default-deny-floor.md)).
- Prometheus already egresses to `cluster`, and Headlamp reads results through
  the apiserver, so neither CNP needed changes.

## Storage

- The storage component is an **aggregated API server backed by SQLite** on a
  5 GiB `iscsi` PVC (`kubescape-storage`). SBOMs, vulnerability manifests,
  posture scans and container profiles live there, not in etcd.
- kubevuln has a second 5 GiB `iscsi` PVC for the Grype DB cache.
- Neither PVC is backed up with Volsync: everything is regenerated by the next
  scans.
- Upstream reports SQLite write contention at ~630 container profiles
  ([storage#409](https://github.com/kubescape/storage/issues/409)). This cluster
  runs ~140 containers, but watch the storage pod if that grows.

### Storage APIService unavailable

While `v1beta1.spdx.softwarecomposition.kubescape.io` is unavailable, API
discovery is degraded: Flux server-side dry-runs, `kubectl api-resources`, and
anything that walks every API group can fail or log errors. The
`KubescapeStorageAPIServiceUnavailable` alert fires after 5 minutes (warning)
and 30 minutes (critical).

1. `kubectl -n kubescape get pods -l app.kubernetes.io/component=storage` and
   its logs; check the `kubescape-storage` PVC (iSCSI) is bound and writable.
2. `kubectl get apiservice v1beta1.spdx.softwarecomposition.kubescape.io -o yaml`
   — `status.conditions` names the failure (`MissingEndpoints`,
   `FailedDiscoveryCheck`).
3. If it can't be fixed quickly, restore discovery by removing the aggregation:

    ```sh
    flux suspend helmrelease kubescape -n kubescape
    kubectl delete apiservice v1beta1.spdx.softwarecomposition.kubescape.io
    ```

    Resume the HelmRelease once the cause is fixed; the APIService is recreated.

The SQLite database is disposable: deleting the PVC (with storage scaled to 0)
resets all results, which the next scans rebuild.

## Expected Talos CIS noise

Talos is immutable and not kubeadm-based, so part of the CIS benchmark does not
apply and will show as failing or unknown. Expect, and don't chase:

- **Control-plane file permission/ownership checks** (CIS 1.1.x) for kubeadm
  paths such as `/etc/kubernetes/manifests/*`, `admin.conf`, PKI directories.
  Talos manages these itself.
- **etcd checks** (CIS 2.x): etcd is a Talos service, not a static pod, so its
  flags are not discoverable the way the benchmark expects.
- **kube-proxy checks**: kube-proxy is not deployed (Cilium replaces it).
- **Kubelet file checks** (CIS 4.1.x) that assume kubeadm locations.
- API server / controller-manager flag checks whose Talos defaults differ from
  the benchmark's literal expectation even when equivalent protection exists
  (e.g. audit logging is configured through the Talos machine config).

Findings in NSA, MITRE and the `security` framework are workload-level and are
the ones worth triaging. If the noise becomes a problem, enable
`riskAcceptance` and manage `ClusterSecurityException` resources in Git.

## Interactions with other policies

- The cluster default-deny floor selects the `kubescape` namespace; the CNPs
  above are the allow-list.
- Kyverno (PR #524, not yet merged): its PSA-label policy only requires an
  explicit `enforce` label, which this namespace has. The planned S7 policy
  "disallow `hostPath` outside `kube-system`/`download`" must also allow
  `kubescape` (node-agent).
- Tetragon (planned): both it and node-agent attach eBPF programs, which is
  supported, but expect node-agent in Tetragon exec/file telemetry (it reads
  `/proc` and the container runtime socket).

## Verification

After Flux reconciles:

```sh
flux get helmrelease kubescape -n kubescape
kubectl -n kubescape get pods,pvc
kubectl get apiservice v1beta1.spdx.softwarecomposition.kubescape.io   # Available=True
kubectl -n kubescape get cm ks-capabilities -o jsonpath='{.data.capabilities}' | jq '.capabilityWarnings'   # []

# Policy drops from the namespace (expect none)
hubble observe --namespace kubescape --verdict DROPPED --last 200

# Trigger scans now instead of waiting for the schedules
kubectl -n kubescape create job --from=cronjob/kubescape-scheduler posture-now
kubectl -n kubescape create job --from=cronjob/kubevuln-scheduler vuln-now

kubectl get workloadconfigurationscansummaries -A | head
kubectl get vulnerabilitymanifestsummaries -A | head
kubectl get kubeletinfos
```

Then check the Grafana dashboard and the Headlamp Kubescape views as a
`k8s_viewers` user. Relevancy data fills in once each workload's learning
period (up to 24 h) completes.
