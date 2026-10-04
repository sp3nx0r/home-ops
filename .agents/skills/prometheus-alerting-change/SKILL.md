---
name: prometheus-alerting-change
description: Authors and verifies Prometheus alerts, Grafana dashboards and Alertmanager routing in home-ops — inventory of chart-shipped rules to avoid duplicates, live checks that every metric and job label exists, lifecycle-based thresholds, promtool/amtool validation of the rendered config, route tests, post-merge rule health, and scrape-coverage audits for "missing" metrics. Use when adding or editing a PrometheusRule, a Grafana dashboard entry, Alertmanager receivers/routes/heartbeats/HA, or when a metric, target or alert seems missing or wrong.
---

# Prometheus alerting change

## Mission

Ship alerts that can fire, don't duplicate what charts already ship, fit the object's real lifecycle, and are loaded and healthy after merge.

## Prerequisites

- `source /opt/home-ops/scripts/o11y.sh` (`q`, `am`; no port-forwards).
- Rule homes: per-app `kubernetes/apps/<ns>/<app>/app/prometheusrule.yaml` (add it to that app's `kustomization.yaml`) or the stack-wide `kubernetes/apps/o11y/kube-prometheus-stack/app/prometheusrule.yaml`. Rules are discovered cluster-wide (`ruleSelectorNilUsesHelmValues: false`).
- Dashboards: `kubernetes/apps/o11y/grafana/app/helmrelease.yaml` → `dashboards.<folder>.<name>` (`url:` or `gnetId:` + `revision:`, plus a `DS_PROMETHEUS` datasource mapping), or a JSON file under `grafana/app/dashboards/` added to that kustomization's `configMapGenerator` with label `grafana_dashboard: "1"` and annotation `grafana_folder: <Folder>` (the sidecar searches all namespaces).
- Alertmanager: config inline at `.spec.values.alertmanager.config` in the kube-prometheus-stack HR; v0.34.1, 1 replica, emptyDir. Details: [alertmanager.md](alertmanager.md).
- `promtool` and `amtool` are installed locally by mise and match the cluster (`promtool --version`, `amtool --version` vs the Alertmanager CR `spec.version`). Use them instead of `kubectl exec` into the pods, which logs an admin exec audit event.

## Workflow

1. **Inventory existing alerts** and grep for every alert you plan to add:
    ```sh
    kubectl get prometheusrule -A -o json | jq -r '.items[] | (.metadata.namespace+"/"+.metadata.name) as $r | .spec.groups[].rules[] | select(.alert) | "\($r) \(.alert)"' | sort > /tmp/existing-alerts.txt
    ```
    Charts ship their own rules: Thanos `thanos-rules` (~20 mixin alerts), kube-prometheus-stack `defaultRules`, `KubeJobFailed`. 20 duplicate Thanos alerts were once shipped and had to be cut back.
2. **Real job labels and metric names** (mixins assume other job names):
    ```sh
    q 'count by (job, namespace) ({__name__=~"thanos_.*|cilium_.*|etcd_.*"})'
    q 'count by (__name__) ({__name__=~"metric_a|metric_b"})'      # any name missing → alert can never fire
    ```
    Live jobs include `kube-etcd`, `cilium-agent`, `hubble-metrics`, `thanos-query`, `thanos-compactor`, `cert-manager`. `jobLabel` can merge jobs: both Vector apps report `job="vector"`, so filter on `namespace`/`pod`. For vendor exporters, verify label **values** in upstream source (`upstream-helm-chart-onboarding` step 17).
3. **Thresholds from the lifecycle, not round numbers.** Read the live objects first. Let's Encrypt certs here last ~160h and renew ~2 days before expiry, so "< 21 days" fires forever. `CertManagerCertRenewalStuck` in `kubernetes/apps/cert-manager/cert-manager/app/prometheusrule.yaml` uses a ratio against the controller's own renewal schedule; copy that pattern. When a schedule changes (a CronJob interval), update the staleness alert in the same PR.
4. **Evaluate each `expr` live** (`q "<expr>"`): usually empty on a healthy cluster, but it must parse. For a replacement rule, compare old vs new at a timestamp in a known-bad window (`q "<expr>" <ts>`).
5. **Lint the rendered rules**:
    ```sh
    kustomize build kubernetes/apps/<ns>/<app>/app | yq 'select(.kind=="PrometheusRule") | .spec' | promtool check rules /dev/stdin
    ```
    Flux postBuild substitutes only braced `${VAR}`, so `{{ $labels.x }}`, `$value` and `$1` are safe (see `backblaze-exporter`). A braced `${1}` in a `label_replace` replacement, or any other `${...}`, gets blanked when the app's `ks.yaml` has `postBuild`; write `$1`, or escape it as `$${1}`.
6. **Dashboards**: `curl -s -o /dev/null -w '%{http_code}' -L <url>` must be 200; the Grafana init container uses `curl -f`, so one bad URL fails the pod. Replace stale dashboards rather than stacking new ones (a statsd-era Envoy `gnetId: 11022` was once kept next to its replacement).
7. **Alertmanager edits**: follow [alertmanager.md](alertmanager.md): render the config Secret, `amtool check-config`, one route test per intended path, CNP `toFQDNs` for new receivers, `sops set` for receiver secrets.
8. **One PR per component**, cut from a freshly fetched `origin/main` (a stale base missed a rule group merged an hour earlier). Match the annotation style (folded `summary`/`description` + `severity`). Comments terse.
9. **Post-merge**:
    ```sh
    kubectl get prometheusrule -A | rg <name>
    kubectl get --raw '/api/v1/namespaces/o11y/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/rules?type=alert' \
      | jq -r '.data.groups[] | select(.name|test("<group>")) | "\(.name) \(.rules|length) " + ([.rules[].health]|unique|join(","))'
    q 'ALERTS{alertstate="firing"}'; q 'prometheus_target_scrape_pool_targets == 0'
    ```
    A group can look unhealthy before its first evaluation (`lastEvaluation` zero); wait one interval (`evaluationInterval` is 30s). Match on the group name inside `spec.groups`, not the PrometheusRule object name: `thanos-rules` contains `thanos-compact`, etc., while repo rules mostly use `<app>.rules`.

## Scrape-coverage audit ("metric is missing")

1. `kubectl get --raw '/api/v1/namespaces/o11y/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/targets' > /tmp/targets.json`. Keys are `data.activeTargets` / `data.droppedTargets`.
2. `kubectl get podmonitor,servicemonitor,probe -A`. Join each monitor's `scrapePool` (`podMonitor/<ns>/<name>/<idx>`) to active targets; flag `health!="up"` and pools with zero targets.
3. Zero targets: compare the monitor's `port` with the pod's port **names** (`kubectl get pod <p> -o jsonpath='{range .spec.containers[*]}{.name}: {range .ports[*]}{.name}={.containerPort} {end}{"\n"}{end}'`). Port names are ≤15 chars: the Vector chart turned sink `prometheus_exporter` into `prometheus-expo`, which never matched `prom-exporter`. Empty pools don't trigger `TargetDown`; `PrometheusScrapePoolEmpty` covers them.
4. Missing scrapes can also be CNP drops on the metrics port (`hubble-drop-triage`).

## Gotchas & Edge Cases

- Stacks of `KubeJobFailed` after a network-policy fix come from failed Jobs created before it. Once the cause is fixed, delete the stale failed Jobs (ask first).
- Distroless containers (Prometheus) lack `wget`/`sh`; use the apiserver proxy instead of exec.
- Grafana dashboard JSON is full of `${DS_PROMETHEUS}`-style variables. It survives only because `grafana/ks.yaml` has no `postBuild`. If you add substitution there, or ship a dashboard ConfigMap from an app that has it, label the ConfigMap `kustomize.toolkit.fluxcd.io/substitute: disabled` (as `gatus` does).
- Watching CI: `gh pr checks <n> --json link` can return the wrong run while pending. Use `gh run list --branch <br> --workflow "Flux Local" --limit 1 --json databaseId -q '.[0].databaseId'` then `timeout 900 gh run watch <id> --exit-status`.
- Heartbeat/dead-man alerts: see [alertmanager.md](alertmanager.md) for `repeat_interval` vs `group_interval` and `send_resolved: false`.

## Output Template

```
## <component> alerts/dashboards — [#<n>](https://github.com/sp3nx0r/home-ops/pull/<n>)
| Alert | Expr (summary) | Metrics verified live | Overlaps existing? | Fires now? |
Dashboards: <name> → <url> (200) in <folder>
Alertmanager: check-config ok; routes <alert → receiver …>; secrets to fill <sops set …>
Post-merge: group <name> loaded, N rules, health ok · firing: <list> · empty scrape pools: none
```
