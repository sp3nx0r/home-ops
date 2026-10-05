---
name: kube-audit-investigation
description: Answers "who did what to the Kubernetes API" from the home-ops apiserver audit stream in Loki ({source="kube-audit"}) — aggregated breakdowns by user, verb, resource and source IP, Secret-access baselines, tracing a ServiceAccount's 403s to the exact HTTP request with impersonation and -v=6, and baselining a new audit-log detection against 7 days of real traffic before shipping it. Use when asked what an OIDC user or ServiceAccount has been doing, why an SA logs forbidden events, before tightening RBAC, or when writing or tuning an audit-based alert.
---

# kube-audit investigation

## Mission

Produce accurate, aggregated answers about API activity, with the real time span stated, without changing anything in the cluster.

## Prerequisites

- `source scripts/o11y.sh` from the repo or worktree (`lq` metric queries, `lqr` raw JSON lines oldest-first, `lqt` newest-first; apiserver proxy, no port-forward). Other log sources and cross-source timelines: `homelab-log-triage`. These are shell functions, so `timeout lq ...` fails; set the Shell call's `block_until_ms` (~120000) instead for `[7d]`/`[30d]` ranges.
- Data model (Vector `audit_parse` → `loki_audit` in `kubernetes/apps/kube-system/vector/app/helmrelease.yaml`):
    - Stream labels: `source="kube-audit"`, `service_name="kube-apiserver-audit"`, **`verb`**. Everything else is JSON in the line (Vector also copies `objectRef.namespace` to a top-level `namespace` key, which is not a label).
    - Policy: `KubeAuditPolicyConfig` in `talos/control-plane/00-cluster.yaml`. Metadata level (no bodies); `RequestReceived` dropped. Secrets are logged with `objectRef.name`, including 403/404 attempts.
    - **The stream starts 2026-09-25.** "Last 30d" covers less; report the real span.
- Alert shipping: `prometheus-alerting-change`. Manifest checks for an RBAC fix: `home-ops-change-validation`.

## Workflow

### A. Activity breakdowns

```sh
S='{source="kube-audit"}'
lq "sum by (user_username) (count_over_time($S | json | user_username=~\"oidc:.*\" [30d]))"
lq "sum by (verb, objectRef_resource, objectRef_subresource) (count_over_time($S | json | user_username=\"<u>\" [30d]))"
lq "sum by (user_username, verb, objectRef_resource) (count_over_time({source=\"kube-audit\", verb!~\"get|list|watch\"} | json [7d]))"   # writes
lq "sum by (ip, ua) (count_over_time($S | json ip=\"sourceIPs[0]\", ua=\"userAgent\", u=\"user.username\" | u=\"<u>\" [30d]))"
lqr "$S |= \"<u>\" | json | objectRef_resource=\"secrets\"" 1440 20 | jq -c '{verb,objectRef,userAgent,code:.responseStatus.code}'
```

- `| json` flattens nested keys with `_` (`user_username`) but **skips arrays**. Extract them explicitly: `json ip="sourceIPs[0]", grp="user.groups"`.
- **One condition per query.** A combined `verb!~"..." or objectRef_subresource!=""` returned empty, and empty can't tell "no hits" from "bad filter". Use the `verb` stream label for read/write splits.
- Lines are compact JSON, so cheap line filters on `"resource":"secrets"` (LogQL backtick strings) go before `| json`.

### B. Trace a ServiceAccount's 403s

1. Quantify:
    ```sh
    lq 'sum by (user_username, verb, objectRef_resource, objectRef_subresource, objectRef_namespace, responseStatus_code) (count_over_time({source="kube-audit"} |= "<sa-fragment>" | json | responseStatus_code=~"40[13]" [2d]))'
    ```
    Then check whether the workload actually fails (`kubectl -n <ns> get jobs`, logs). 404/409 are normal get-then-create.
2. Read the Role (note `resourceNames`) and the code that makes the calls.
3. A namespaced Role can never grant cluster-scoped resources. If the denied object is the Namespace, find out **who** asks for it before adding a ClusterRole.
4. Reproduce as the SA with request tracing, using a name `resourceNames` allows:
    ```sh
    SA=system:serviceaccount:<ns>:<sa>
    kubectl --as=$SA -n <ns> get job <allowed-name> --ignore-not-found -v=6 2>&1 | rg 'verb=' \
      | sed -E 's/.*verb="([A-Z]+)" url="[^"]*6443([^"?]*)[^"]*" status="([^"]*)".*/\1 \2 \3/'
    kubectl --as=$SA get --raw /apis/batch/v1/namespaces/<ns>/jobs/<name> -v=6 2>&1 | rg 'verb='   # raw: no client-side extras
    ```
5. Fix the client, not the RBAC. Worked example (fixed on main): `kubectl get|delete --ignore-not-found` sends a follow-up `GET /api/v1/namespaces/<ns>` after a 404, which caused ~25 denials per run for every Volsync `*-cache-scrub` CronJob. Use `kubectl get --raw`/`delete --raw`, match `(NotFound)` in stderr, and **fail closed** on any other error. Fix every copy of the logic (`kubernetes/components/volsync/cache-scrub.yaml` and any app-local copy).
6. Test the new script live without mutations: append `?dryRun=All` to mutating raw paths and run it through a wrapper on `PATH` (`exec kubectl --as=$SA "$@"`). Test the normal path, a forbidden name (must exit non-zero before deleting), and NotFound.

### C. Baseline a detection before shipping it

1. Confirm the field shape on one real event:
    ```sh
    lqr '{source="kube-audit", verb="get"} |= `"resource":"secrets"`' 60 1 | jq .
    ```
2. Baseline comparable objects over 7 days. Expected principals here:
    - `flux-system:kustomize-controller` does `get`/`patch`/`create` on every reconcile (SSA, including dry-run).
    - Kubelets (`system:node:*`) only `watch` mounted Secrets.
    - Informers (reloader etc.) do unnamed cluster-wide `watch`.
    - `admin` is the owner's kubeconfig. Don't allowlist it if a stolen kubeconfig is in the threat model.
3. Bucket unnamed `list`s by selector:
    ```logql
    sum by (user, sel) (count_over_time({source="kube-audit", verb="list"} |= `"resource":"secrets"`
      | json user="user.username", name="objectRef.name", uri="requestURI" | name=""
      | label_format sel=`{{ if contains "labelSelector=" .uri }}label{{ else if contains "fieldSelector=" .uri }}field{{ else }}none{{ end }}` [7d]))
    ```
    Fixed selectors seen: helm (`owner%3Dhelm`), Grafana sidecars (`grafana_dashboard`, `grafana_datasource`), Loki sidecar (`loki_rule`).
4. Exclude narrowly: by principal **and** verb (a prune `delete` must still alert). Exclude selector-scoped lists only when the selector positively requires a key the target lacks; match URL-encoded and raw forms. Unit-test the regex with `grep -E` on sample URIs.
5. Test the **exact** `expr` from the rule file with the window swapped to 7d; report events scanned, matches, and who matched. A named `kubectl get secret <decoy>` that 404s is a valid end-to-end test (404s are logged).
6. Loki ruler: not on main. [#554](https://github.com/sp3nx0r/home-ops/pull/554) adds it (Sigma pipeline, `searchNamespace: ALL`, tenant path `/rules/fake`). On main the `loki-sc-rules` sidecar has `LABEL=loki_rule`, `FOLDER=/rules`, own namespace only. Check the live env before choosing where a rule ConfigMap goes.

## Gotchas & Edge Cases

- Headlamp OIDC calls show the **workstation** as `sourceIPs[0]` (192.168.5.181), not the pod; tell it from kubectl by `userAgent`. Anonymous 403s right after OIDC activity are usually Headlamp retrying with an expired token.
- **Your own investigation shows up in the data.** `kubectl exec` is an `admin` exec event; impersonation shows as admin with `impersonatedUser`. Detections on admin activity may fire, so tell the user and exclude your timestamps/IP from baselines.
- `resourceNames` makes a fake name return 403, not 404, so the "absent" path can't be tested directly; say which verified path it shares.
- `exit` inside `$(...)` only ends the subshell. Capture stderr to a file and inspect it.
- A detection matching only `objectRef.name` misses bulk `list` dumps; add an unnamed-list rule. `kubectl get secrets -w` lists before watching, so it's covered.
- Rule window: `count_over_time([5m]) > 0` with `for: 0m` absorbs Vector batching. It resolves ~5 minutes after the last event.
- One bad rule file blocks every rule under local ruler storage. Always parse-check.

## Output Template

```
Audit window: <earliest> → <now> (<N> days; stream starts 2026-09-25)
Subjects: <user> <count> (<userAgent>, <sourceIP>)
Verbs: watch N · list N · get N; writes: <none|list>; subresources: <none|list>
Notable: <secret reads, exec, anonymous, 403s>
403 trace (as <sa>, -v=6): <METHOD path status> … → cause → fix → dryRun tests ✔
Detection <name>: 7d scanned <n>, matches <n> (<who>); exclusions <…> justified by <query>
Self-generated events: <times/IP, if any>
```
