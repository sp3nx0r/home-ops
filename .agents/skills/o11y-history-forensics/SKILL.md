---
name: o11y-history-forensics
description: Queries the home-ops Prometheus, Thanos, Loki and Alertmanager through the kube-apiserver service proxy (no port-forwards) to verify a reported symptom, build an incident timeline, read historical logs, and size requests/limits from Thanos history without overclaiming from partial data. Use when the user says an app "keeps crashlooping", "is slow" or "was down last night", asks "what happened at <time>", wants resources right-sized, or whenever an agent is about to port-forward to Prometheus, Loki or Thanos.
---

# o11y history and forensics

## Mission

Answer "what happened, and why" from metrics and logs, with the coverage and confidence stated, instead of reading a pod's current state or guessing.

## Prerequisites

- Run inside the repo (or a worktree with the kubeconfig symlinked) so mise sets `KUBECONFIG`, then `source scripts/o11y.sh`. [o11y.sh](../../../scripts/o11y.sh) defines `q`/`qr` (Prometheus), `tq`/`tqr` (Thanos Query / Query Frontend, `partial_response=false`), `lq`/`lqr` (Loki metric / raw lines), `lqt` (newest-first lines with time and labels), `lpat` (Loki patterns, last ~3h) and `am` (active alerts). Log sources beyond pod logs (NAS syslog, audit, Hubble): `homelab-log-triage`. All go through `kubectl get --raw /api/v1/namespaces/o11y/services/<svc>:<port>/proxy/...`.
- **CLIs** (mise installs `logcli`, `promtool`, `amtool`): run `o11y_cli_env` once per shell. It writes the kubeconfig client cert to `$XDG_RUNTIME_DIR/home-ops-o11y` and exports `LOKI_*`, `PROM_URL`, `THANOS_URL` (Query Frontend), `ALERTMANAGER_URL` and `O11Y_HTTP_CONFIG`. Run `o11y_cli_clean` when done. Use the CLIs for big pulls the helpers handle badly:
    ```sh
    logcli query --since=24h --limit=50000 --batch=5000 -o raw '{namespace="<ns>", pod=~"<app>.*"} |= "error"' > /tmp/logs.jsonl
    logcli series --since=1h '{namespace="<ns>"}'              # which streams/labels exist
    promtool query range --http.config.file="$O11Y_HTTP_CONFIG" --start=$(date -d -14days +%s) --end=$(date +%s) --step=1h "$THANOS_URL" '<promql>'
    ```
    `lqr` stops at one request's `limit`; `logcli --batch` pages through it. Quick checks stay with the helpers, which need no setup.
- Retention: Prometheus 7d/5GB; Thanos raw 14d, 5m 30d, 1h 90d; Loki 30d (`retention_period: 720h`). Gatus: `kubectl get --raw /api/v1/namespaces/o11y/services/gatus:80/proxy/api/v1/endpoints/statuses` (timestamps UTC).
- Related: `hubble-drop-triage` (network drops), `flux-rollout-watch` (post-change verification).

## Workflow

### A. Verify the symptom and build a timeline

1. **Treat the user's label as a hypothesis.** "Lots of crashloops" was 0 restarts in 14 days; "database errors" were DEBUG statement logs.
    ```sh
    tq 'increase(kube_pod_container_status_restarts_total{namespace="<ns>",pod=~"<app>.*"}[14d]) > 0'
    tq 'max_over_time(kube_pod_container_status_last_terminated_reason{namespace="<ns>",pod=~"<app>.*"}[14d])'
    tq 'sort_desc(increase(kube_pod_container_status_restarts_total[3d]) > 2)'     # the real crashloopers
    ```
2. **Readiness timeline**: `tqr 'min_over_time(kube_pod_container_status_ready{namespace="<ns>",pod=~"<app>-.*"}[30m])' 72 1800`. Distinguish periodic dips (a cron at a fixed minute) from a sustained drop starting at a specific time. Repeat for dependencies.
3. **Logs for the window, from Loki.** Kubelet logs cover only the current file (≈1h with debug). Pod records are Vector-wrapped: the app's line is in `.message` (JSON apps: `fromjson? // .`).
    ```sh
    lq 'sum by (detected_level) (count_over_time({namespace="<ns>", pod=~"<app>.*"}[1h]))'
    lqr '{namespace="<ns>", pod=~"<app>.*"} | detected_level=~"warn|error" != "<noisy msg>"' 180 5000 \
      | jq -r '.message | (fromjson? // .) | if type=="object" then "\(.timestamp // .ts // "") \(.level // "") \(.msg // .fields.message // "")" else . end' \
      | sort | uniq -c | sort -rn | head -30
    ```
    `detected_level` works as a **pipeline filter**, not inside `{}`. Filter noise server-side, or the line limit fills with DEBUG.
4. **Probe health endpoints** when readiness is the issue. Compare `/healthz` and `/readyz` latency via `kubectl exec` (or a PID-tracked port-forward). Fast liveness with a hanging readiness check means a shared resource (DB pool, upstream API) is blocking.
5. **App metrics and upstream code**: scrape `/metrics` for loop/queue/DB timings and graph them with `qr`/`tqr`. Read the health-check source at the pinned tag (`gh api "repos/<o>/<r>/contents/<path>?ref=<tag>" --jq .content | base64 -d`).
6. **Correlate with changes**: `git log --oneline -15 -- kubernetes/apps/<ns>/<app>`. Also check Renovate merges and CNP rollouts around the start time. For storage symptoms (slow SQLite/DB writes, fsync timeouts), graph per-device latency before blaming the app: `tqr 'rate(node_disk_write_time_seconds_total[5m]) / rate(node_disk_writes_completed_total[5m])' 72 1800` and find noisy neighbours on the same iSCSI pool.

### B. Size requests and limits from history

1. Container names from the live pod (sidecars need their own values): `kubectl -n <ns> get pod -l <sel> -o jsonpath='{range .items[0].spec.containers[*]}{.name} {.resources}{"\n"}{end}'`.
2. **Coverage first**:
    ```sh
    mem='max(container_memory_working_set_bytes{namespace="<ns>",pod=~"<app>-.*",container="<c>"})'
    tq "count_over_time(($mem)[45d:1h])"       # hours with data vs workload age
    tq 'count(up{job="apiserver"} offset 25d)'  # non-empty: store gateway can read old blocks
    ```
3. **Light queries**: one container per query, wrapped in `max()`, 15m–1h subquery steps:
    ```sh
    for c in <c1> <c2>; do
      cpu="max(rate(container_cpu_usage_seconds_total{namespace=\"<ns>\",pod=~\"<app>-.*\",container=\"$c\"}[5m]))"
      mem="max(container_memory_working_set_bytes{namespace=\"<ns>\",pod=~\"<app>-.*\",container=\"$c\"})"
      for f in "quantile_over_time(0.5," "quantile_over_time(0.99," "max_over_time("; do
        echo "$c $f cpu=$(tq "$f ($cpu)[45d:15m])" | jq -r .v) mem=$(tq "$f ($mem)[45d:15m])" | jq -r .v)"; done
    done
    ```
4. **Convention**: CPU request ≈ p99 (floor `10m`), **no CPU limit**. Memory request ≥ observed max, rounded to 16Mi/32Mi steps; memory limit ≈ 2–3× max. A CPU-utilization HPA needs a CPU request; if `request × target%` is far above the peak, it never scales (suggest removing it).

## Gotchas & Edge Cases

- **The Loki `namespace` label lies for JSON-logging pods.** Vector merges the app's JSON over the Kubernetes metadata, so Flux controllers and Kubescape pods carry the `namespace` of whatever object they logged about. Select those by `pod=~"<name>.*"`, not `namespace`.
- **Partial data posed as fact.** Every query once returned ≈51h, and the agent reported "Thanos has no history". In fact the store gateway had been OOM-killed by a `[60d:5m]` query, and Query served only sidecar data. Server-side `--no-query.partial-response` now makes this an error. Still read `.warnings`, and state coverage in every answer.
- **Broad queries crash Thanos.** `{__name__=~".+"}` and long fine-step subqueries OOM'd query/store. Store limits (`request-series=100000`, `request-samples=50000000`) now reject them; narrow the query rather than raising the limits. If you did cause a restart, tell the user.
- Instant subqueries via `tq` skip Query Frontend's 24h splitting. Use `tqr` for long ranges.
- Old offsets can return empty at coarse resolution because of lookback; that isn't data loss. Check the retention block in `kubernetes/apps/o11y/thanos/app/helmrelease.yaml`.
- Coverage that starts on a suspicious date may be a scrape gap (a CNP change cut cAdvisor scraping on Sep 28–29). Check `git log` on `kube-prometheus-stack` and the network policies.
- **A `BadRequest` from the proxy** with no detail means a malformed expression (e.g. a missing comma after the `quantile_over_time` quantile). Simplify and retry.
- `promtool query` has no partial-response flag. Thanos Query runs with `--no-query.partial-response`, so a partial result is an error rather than silent. Still read stderr.
- `logcli` defaults to `--limit=30`; always set `--limit` and `--batch`, and `--since`/`--from` in UTC.
- Port-forwards are the fallback, not the default. If one is unavoidable, capture `$!` and `kill` that PID. `pkill -f '<pattern>'` in the same command line killed the agent's shell in many sessions. `svc/loki-gateway` forwards dropped silently; use `svc/loki:3100`.
- Use UTC for queries and `--since-time`; report in the owner's local time (UTC-5) and say so.
- Name confounds: a pod "recovered" because the load left, not because of a fix.

## Output Template

```
Coverage: <source> <N h of data, start → now>, partial_response=false, warnings: none
Symptom check: <crashloop? restarts N/14d> · ready fraction <x%> (3d)
Timeline (UTC-5): <periodic dips at :MM> / <sustained from HH:MM> / <recovered HH:MM because …>
Cause: <evidence: log counts, metric values, upstream code line>
Noise vs real: <what the user saw vs what it is>
Sizing: | container | CPU p99/max | Mem p99/max | set to |
Options (nothing changed): 1 quick relief · 2 real fix · 3 upstream issue
```
