# Loki ruler detections (detection-as-code)

Log-based alerting for the cluster: the Loki ruler evaluates LogQL alert rules
that come from Git, and sends them to the existing Alertmanager → Discord.
Security detections for the kube-apiserver audit log are written in
[Sigma](https://sigmahq.io/) (vendored SigmaHQ rules plus homelab rules) and
converted to LogQL with pySigma. Implements O6 and the first part of P2 in
`docs/sre-and-security-evaluation.md`.

## Pipeline

```
kube-apiserver audit file ─► Vector (kube-system) ─► Loki {source="kube-audit"}
pod logs / syslog / hubble ─► Vector ─────────────► Loki {source="kubernetes"|"syslog"|"hubble"}
                                                        │
ConfigMaps labeled loki_rule="true" (any namespace)     │ evaluated every 1m
  └─► loki-sc-rules sidecar ─► /rules/fake/*.yaml ─► Loki ruler (in loki-0)
                                                        │ alertmanager_url
                                                        ▼
                                           Alertmanager (o11y) ─► Discord
```

- **Ruler**: the embedded ruler of the SingleBinary Loki (`loki-0`). Rule
  storage is `local` at `/rules`; the tenant is `fake` because
  `auth_enabled: false`, so the files live in `/rules/fake/`. The old
  `loki-ruler` S3 bucket is no longer used for rules.
- **Sidecar**: `loki-sc-rules` (kiwigrid k8s-sidecar, from the chart's
  `sidecar.rules`) watches ConfigMaps cluster-wide (`searchNamespace: ALL`,
  `resource: configmap`) with label `loki_rule=true` and writes each data key to
  `/rules/fake/namespace_<ns>.configmap_<name>.<key>`
  (`enableUniqueFilenames: true`). The ruler polls that directory every minute.
  The chart's ClusterRole is patched (HelmRelease `postRenderers`) to
  `configmaps` get/list/watch only; it no longer grants cluster-wide Secret reads.
- **Alerts**: every alert gets `source: loki-ruler` (ruler `external_labels`;
  a rule's own label wins). Network path: `loki-backend` CNP egress → the
  `alertmanager` CNP ingress on :9093.

## ConfigMap convention (for any app adding Loki rules)

| Item      | Value                                                                                                                 |
| --------- | --------------------------------------------------------------------------------------------------------------------- |
| Kind      | `ConfigMap`, in **any** namespace                                                                                     |
| Label     | `loki_rule: "true"` (exact value; other values are ignored)                                                           |
| Data keys | One Loki/Prometheus rule-group file per key, e.g. `canary.yaml`. **Only** rule files: every key becomes a rule file   |
| Format    | `groups: [{name, interval?, rules: [{alert, expr: <LogQL>, for?, labels, annotations}]}]`                             |
| Tenant    | `fake` (implicit; nothing to set)                                                                                     |
| Labels    | `severity: critical \| warning \| info` (required). Security detections also set `category: security`                 |
| Flux      | If the Flux Kustomization uses `postBuild`, annotate the ConfigMap `kustomize.toolkit.fluxcd.io/substitute: disabled` |

Example (kustomize generator, as `kubernetes/apps/o11y/loki/app/kustomization.yaml` does):

```yaml
configMapGenerator:
    - name: loki-rules-canarytokens
      files:
          - ./rules/canarytokens.yaml
generatorOptions:
    disableNameSuffixHash: true
    labels:
        loki_rule: "true"
    annotations:
        kustomize.toolkit.fluxcd.io/substitute: disabled
```

Rules:

- **Validate before merging**: `just sigma lint` (offline LogQL parse and
  severity check of every rule group under `kubernetes/`, including inline
  `loki_rule` ConfigMaps) and `just sigma validate <file>` (runs each rule
  against live Loki over 7 days and reports how many 5-minute windows would fire).
- **One bad file blocks everyone.** With local storage, a rule file that fails
  to parse (YAML, rule schema, or LogQL) makes the ruler's rule listing fail
  for the whole tenant. Rules already loaded keep running, but no change
  applies, and after a restart nothing loads. `LokiRulerRuleSyncFailing` (Loki)
  and `LokiRulerNoRuleGroups` (Prometheus) catch this.
- Group names only need to be unique per file (the file name is the rule
  namespace).
- Alert labels come from the `sum by (...)` in `expr` plus `labels:`. Keep
  high-cardinality fields (pod UIDs, IPs) out of `by (...)`.

### Routing

| Labels                                            | Receiver                                                                                                                         |
| ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `category=security`, `severity=critical\|warning` | `discord-security`: grouped by `alertname` + `user`, `send_resolved: false`; message = `summary` annotation + runbook/rule links |
| other `severity=critical\|warning`                | `discord` (the existing route)                                                                                                   |
| `severity=info` (or anything else)                | `blackhole`: visible in the Alertmanager UI and Grafana, never notified                                                          |

Security alerts are point-in-time events. They stay active for about one
lookback window (5m) after the last matching event, then resolve, so a
"resolved" notice would be noise.

## Data available in `{source="kube-audit"}`

Each line is the raw `audit.k8s.io/v1` Event JSON. Stream labels are `source`,
`service_name`, and `verb`. `| json` flattens fields with `_`:
`user_username`, `objectRef_resource`, `objectRef_subresource`,
`objectRef_namespace`, `objectRef_name`, `objectRef_apiGroup`,
`responseStatus_code`, `requestURI`, `userAgent`. Vector also adds a top-level
`namespace`. Arrays (`sourceIPs`, `user_groups`) are not flattened.

What is **not** there (audit policy in `talos/control-plane/00-cluster.yaml`,
filters in the Vector HelmRelease):

- Level `None`: token/subject-access reviews (incl. `selfsubjectrulesreviews`),
  lease get/watch/update/patch, control-plane and kubelet reads, endpoint /
  endpointslice / event reads, health/version/discovery/metrics URLs.
- Secrets, ConfigMaps, and `serviceaccounts/token` are **Metadata** only (no
  bodies). So are pods and Services, so pod specs (`hostPath`, privileged,
  capabilities) and Service `type` are not visible. Only RBAC, webhooks,
  NetworkPolicy/CNP/CCNP, and CSRs are logged at `Request` level.
- Vector drops `RequestReceived` stages and the `events` and `leases` resources.

Gotchas the rules handle:

- `kubectl exec`/`port-forward` over WebSocket (the default) is audited with
  verb **`get`**, not `create`.
- `kubectl apply --dry-run=server` is audited like a real write (`dryRun=All`
  in `requestURI`). The Sigma pipeline excludes it globally. It is a JSON-field
  filter, not a line filter, so a client cannot hide a real request by putting
  `dryRun=` in its User-Agent.
- `admin` is the Talos-generated break-glass certificate the owner (and
  automation) use daily; `talos:admin` is Talos' own control-plane identity.

## Layout and regeneration

```
sigma/
  config.yaml                SigmaHQ pin + rule list + per-rule output overrides
  pipelines/kube-audit-loki.yml  pySigma pipeline: stream selector, json parser, field mapping, dry-run exclusion
  filters/*.yml              Sigma filters (tuning); each lists the rule IDs it applies to
  rules/homelab/*.yml        hand-written Sigma rules
  vendor/sigmahq/...         upstream rules vendored at the pinned SigmaHQ commit
  mod.just                   `just sigma ...`
scripts/sigma-to-loki.py     generator (PEP 723 script; pySigma versions pinned inline, run via uv)
kubernetes/apps/o11y/loki/app/rules/
  sigma-kube-audit.yaml      GENERATED -- do not edit
  loki-ruler-health.yaml     native LogQL
```

Pinned toolchain: `pysigma==1.5.1`, `pysigma-backend-loki==0.14.0`,
`pyyaml==6.0.3` (inline script metadata), `uv`/`oxfmt`/`loki-logcli` from
mise. SigmaHQ is pinned to `07ec293a51695cb1131a2e05260247872b31e1e1`
(2026-09-25).

| Task                    | Command                                                                                                                    |
| ----------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Regenerate after edits  | `just sigma generate` (also runs `lint`)                                                                                   |
| Stale check             | `just sigma check`                                                                                                         |
| Offline lint            | `just sigma lint [paths]`                                                                                                  |
| Live 7-day firing count | `just sigma validate [files]` (port-forwards to `loki-0`)                                                                  |
| Bump SigmaHQ            | edit `sigmahq.ref` (and `rules`) in `sigma/config.yaml`, `just sigma vendor`, `just sigma generate`, `just sigma validate` |

The generator emits, per rule:

```
sum by (<group_by>) (count_over_time(<Sigma LogQL> | label_format user=user_username, ... [5m])) > <threshold>
```

with labels `severity`, `category: security`, `sigma_id` and annotations
`summary`, `description`, `sigma_rule` (link to the pinned upstream or
homelab source), and `runbook_url`. Severity comes from the Sigma level
(`low`→`info`, `medium`→`warning`, `high`/`critical`→`critical`) unless
`config.yaml` overrides it.

### Adding a detection

1. Write `sigma/rules/homelab/<name>.yml` (logsource `product: kubernetes`,
   `service: audit`; fresh UUID `id`; field names as in the audit JSON, dotted).
2. Add its ID under `outputs[].rules` in `sigma/config.yaml` (plus overrides).
3. If automation matches it, add the ID to `filters/gitops-and-control-plane.yml`
   and/or write a narrow filter (scope by principal **and** resource).
4. `just sigma generate && just sigma validate`: tune until warning/critical
   rules fire only on activity that should reach Discord.

For non-audit sources (syslog, Hubble, pod logs) write native LogQL in a
separate rule file and add it to a `configMapGenerator`; the Sigma pipeline
only handles `kubernetes/audit`.

## Detections

Observed column: 5-minute evaluation windows that would have fired over the 7
days to 2026-09-30, from `just sigma validate` against live Loki. "≈ Discord"
is the number of notification bursts after grouping by alertname + user.

| Alert                                          | Source         | Severity | Observed 7d | ≈ Discord / week | Notes                                                                        |
| ---------------------------------------------- | -------------- | -------- | ----------- | ---------------- | ---------------------------------------------------------------------------- |
| KubernetesAdmissionControllerModification      | SigmaHQ        | warning  | 0           | 0                | cainjector / kps-admission / tuppr caBundle patches filtered                 |
| KubernetesCronJobJobModification               | SigmaHQ        | warning  | 1           | 1                | volsync + controllers filtered; `admin` Job deletes/triggers filtered        |
| DeploymentDeletedFromKubernetesCluster         | SigmaHQ        | info     | 2           | -                |                                                                              |
| CreationOfPodInSystemNamespace                 | SigmaHQ        | warning  | 2           | 1                | subresources (exec/binding/eviction), controllers, mirror pods filtered      |
| KubernetesRolebindingModification              | SigmaHQ        | warning  | 3           | 1                | Flux + volsync mover RBAC filtered                                           |
| KubernetesSecretsEnumeration                   | SigmaHQ        | info     | 7           | -                | helm-controller + grafana sidecar filtered                                   |
| KubernetesSecretsModifiedOrDeleted             | SigmaHQ        | warning  | 14          | 2                | prometheus-operator, cert-manager, Flux, Talos filtered; `admin` remains     |
| NewKubernetesServiceAccountCreated             | SigmaHQ        | info     | 0           | -                | `serviceaccounts/token` (kubelet refresh) filtered                           |
| PotentialSidecarInjectionIntoRunningDeployment | SigmaHQ        | info     | 3           | -                | `kubectl rollout restart` is a deployment patch                              |
| KubernetesUnauthorizedOrUnauthenticatedAccess  | SigmaHQ        | warning  | 0           | 0                | threshold: >20 per principal per 10m; cache-scrub 403s filtered              |
| KubernetesInteractivePodAccess                 | homelab        | warning  | 0           | 0                | exec/attach/portforward/proxy/debug by anyone but `admin`                    |
| KubernetesBreakGlassAdminInteractivePodAccess  | homelab        | info     | 121         | -                | same, `admin` only (~360 sessions/week)                                      |
| KubernetesRoleOrClusterRoleModification        | homelab        | warning  | 3           | 1                |                                                                              |
| KubernetesNetworkPolicyModification            | homelab        | warning  | 3           | 2                | CNP/CCNP/NetworkPolicy; cilium-operator status writes ignored                |
| KubernetesSecretReadByOIDCUser                 | homelab        | warning  | 2           | 1                | Headlamp Secret views                                                        |
| KubernetesWriteByOIDCUser                      | homelab        | warning  | 0           | 0                |                                                                              |
| KubernetesRBACSecretOrWebhookWriteByOIDCUser   | homelab        | critical | 0           | 0                | S2: IdP ⇒ cluster-admin path                                                 |
| KubernetesAnonymousRequestAllowed              | homelab        | critical | 0           | 0                | public-info-viewer health URLs excluded                                      |
| LokiRulerRuleSyncFailing                       | native LogQL   | warning  | 0           | 0                | invalid `loki_rule` file                                                     |
| KubeServiceExposureAdded                       | PrometheusRule | warning  | 0\*         | 0                | new LoadBalancer/NodePort (kube-state-metrics; type is not in the audit log) |

\* A backfill against local Prometheus shows one burst for all 9 exposed
Services at the TSDB retention edge (~2.5 days). Live evaluation always has the
full 1-day lookback, so this only happens if the Prometheus TSDB is wiped.

Everything in the warning rows so far is the owner's own out-of-band activity
(`admin` kubeconfig or Headlamp): about 9 Discord messages a week. If that's
too chatty, downgrade a rule in `sigma/config.yaml` rather than filtering
`admin` out.

Upstream SigmaHQ Kubernetes rules **not** adopted, and why, are listed in
`sigma/config.yaml` (need pod specs, need `None`-level resources, or are
broken upstream).

### Ruler health (`kubernetes/apps/o11y/loki/app/prometheusrule.yaml`)

| Alert                           | Severity | Fires when                                                            |
| ------------------------------- | -------- | --------------------------------------------------------------------- |
| LokiRulerNoRuleGroups           | critical | Loki is up but no rule groups are loaded for 15m                      |
| LokiRulerEvaluationFailures     | warning  | any `loki_prometheus_rule_evaluation_failures_total` increase for 15m |
| LokiRulerMissedIterations       | warning  | a group overran its interval                                          |
| LokiRulerNotificationsFailing   | critical | notification errors/drops, or no Alertmanager discovered              |
| LokiRulerRuleSyncFailing (Loki) | warning  | "unable to list rules" in the loki container log                      |

## Post-merge verification

1. Flux rolls `loki-0` (sidecar env + config change). Check the sidecar found
   the rules: `kubectl -n o11y logs loki-0 -c loki-sc-rules | grep -i writing`.
2. The ruler loaded them:
   `kubectl -n o11y port-forward pod/loki-0 3100 & curl -s localhost:3100/prometheus/api/v1/rules | jq '.data.groups[].name'`
   should list `sigma-kube-audit` and `loki-ruler-health`.
3. Prometheus: `loki_prometheus_rule_group_rules{job="o11y/loki"}` is present
   and `loki_prometheus_notifications_alertmanagers_discovered` is 1.
4. End-to-end: from a non-admin identity (for example Headlamp), open a shell
   in any pod. `KubernetesInteractivePodAccess` should reach Discord through
   `discord-security` within about 2 minutes. Break-glass `admin` exec only
   shows up as an info alert in Alertmanager.
5. `kubectl auth can-i list secrets --as=system:serviceaccount:o11y:loki -A`
   now returns `no`.

## Follow-ups

- CI: run `just sigma check` and `just sigma lint` in the flux-local workflow
  (needs uv + mise tools on the runner, and a path filter for `sigma/**`).
- Set a fixed `uid` on the Grafana Loki datasource and the ruler's
  `datasource_uid`/`external_url`, so alert links open Grafana Explore.
- The Volsync cache-scrub Role is namespaced but the job calls
  `get namespace` (25 × 403 per run, every app); fix the job/Role.
- More sources: Hubble policy drops from world-facing pods, UniFi IPS (syslog
  CEF), Pocket ID admin actions, and Tetragon once P1 lands.
