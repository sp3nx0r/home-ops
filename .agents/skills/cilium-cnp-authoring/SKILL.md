---
name: cilium-cnp-authoring
description: Writes, tightens and audits CiliumNetworkPolicies in home-ops under the cluster default-deny floor, covering hidden dependencies that broke this cluster before, both sides of every connection, and live proof after merge. Use when adding an app's ciliumnetworkpolicy.yaml, putting a shared server (Prometheus, Loki, Garage, Thanos) behind a CNP, narrowing `world` egress, auditing all policies, or when a client starts timing out after a CNP change.
---

# Cilium CNP authoring and audit

## Mission

Ship CNPs that don't silently break traffic. Schema checks pass easily; the outages here came from hidden paths, missing peer-side rules, and skipping the post-merge check.

## Prerequisites

- AGENTS.md "Network Policy" covers floor semantics, common allow rules, and `ndots: 1` for `toFQDNs`. Don't re-derive them.
- `docs/completed/cluster-default-deny-floor.md` has the design and the expected-drops list.
- [reference.md](reference.md) holds the hidden-dependency table, the fan-out audit prompt, and LB/NodePort/hostPort exposure.
- Related skills: `hubble-drop-triage` (finding drops), `flux-rollout-watch` (post-merge watch and HelmRelease recovery).

## Workflow

1. **Map the real traffic from the live cluster**, not only the manifests:
    ```sh
    kubectl -n <ns> get pods --show-labels                      # endpointSelector basis; operator pods may lack app.kubernetes.io/name
    kubectl -n <ns> get svc -o custom-columns='N:.metadata.name,P:.spec.ports[*].port,TP:.spec.ports[*].targetPort,PROTO:.spec.ports[*].protocol'
    rg -n '\.svc(\.cluster\.local)?|https?://' kubernetes/apps/<ns>/<app>/app/helmrelease.yaml   # every configured upstream
    ```
    - Policy matches the **pod port** (after DNAT), not the Service port. Envoy proxies listen on **:10080/:10443**, not 80/443.
    - Pods calling `https://<app>.${SECRET_DOMAIN}` go through the envoy-internal LB IP to the proxy on `:10443` (some hit `:10080` first, then redirect). Allow both.
    - Selector-less Services (`*-proxy` + EndpointSlice) have no pods; the policy belongs on the client.
2. **Walk the hidden-dependency table** in [reference.md](reference.md) for every workload pattern you touch (cloudflared 7844, envoy-gateway → OIDC discovery, Flux → notification-controller, operators → kube-apiserver, thanos-sidecar → Garage, ...).
3. **Audit both sides when the change touches a server.** A server CNP can break clients whose manifests never changed: kromgo already allowed egress to Prometheus, but the Prometheus CNP didn't list it, so every badge hung.
    ```sh
    # every Service fronting the server pods (one pod often has several)
    kubectl -n <ns> get endpointslices -o json | jq -r '.items[] | select(any(.endpoints[]?; .targetRef.name|test("^<server>"))) | .metadata.labels["kubernetes.io/service-name"]' | sort -u
    rg -n '<svc-a>|<svc-b>' kubernetes/apps                     # bare names: charts template the namespace
    yq 'select(.kind=="CiliumNetworkPolicy") | select(.spec.egress[]?.toEndpoints[]?.matchLabels["app.kubernetes.io/name"]=="<server>") | filename' \
      kubernetes/apps/*/*/app/ciliumnetworkpolicy.yaml | sort -u
    ```
    Every caller needs **egress in its CNP and ingress in the server's CNP** on the pod port. Files may hold several CNPs (`kube-prometheus-stack`), so `select(.metadata.name==...)`. Callers via a proxy (Grafana → `thanos-query-frontend`) don't need a direct rule. Loopback sidecars need none.
4. **Write the CNP** at `app/ciliumnetworkpolicy.yaml` (schema comment line 1), add it to `app/kustomization.yaml`:
    - Keep `fromCIDR`/`toCIDR`/`toCIDRSet` and `fromEntities`/`toEntities` in **separate rules**. A combined rule is `Valid=False`.
    - A CIDR rule without `toPorts` allows every port. Quote ports as strings: `port: "9090"`.
    - `world` includes the LAN. Classify each world rule: public-only (use the AGENTS.md `toCIDRSet` + full except-list), needs a LAN host (scope to `/32`), or inherently broad (Flux sources on 443; document why).
    - For cross-namespace Services, use `toEndpoints` with `io.kubernetes.pod.namespace` + the backend pod label, never a ClusterIP CIDR.
    - Comments: one terse line per rule. The owner rejected verbose policy comments twice.
5. **Validate**:
    ```sh
    kustomize build kubernetes/apps/<ns>/<app>/app > /dev/null
    kubectl apply --dry-run=server -f kubernetes/apps/<ns>/<app>/app/ciliumnetworkpolicy.yaml
    ```
    Dry-run each CNP file separately; concatenating builds without `---` silently drops a document. Dry-run checks the CRD schema only. Cilium's semantic validity shows in `VALID` after apply.
6. **PR body**: per-policy ingress/egress summary and the post-merge checklist below.
7. **After merge and reconcile (mandatory)**:
    ```sh
    flux get ks -A --status-selector ready=false
    kubectl get cnp -A -o json | jq -r '.items[] | select(any(.status.conditions[]?; .type=="Valid" and .status=="False")) | "\(.metadata.namespace)/\(.metadata.name)"'
    CIL=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=<node> -o name)
    kubectl -n kube-system exec "$CIL" -c cilium-agent -- cilium-dbg endpoint list | rg 'ENDPOINT|<podIP>'   # POLICY Enabled/Enabled
    ```
    Then watch drops cluster-wide (`hubble-drop-triage`, live mode) **while exercising the real path**: hit the route, trigger the webhook, run the CronJob. Use `curl -sS -o /dev/null -w '%{http_code}\n' https://echo.${SECRET_DOMAIN}/` for the tunnel (530 = tunnel down). A quiet minute doesn't prove nightly/hourly paths; offer a soak or a "verify on next trigger" note.
8. **Fix regressions through Git.** kustomize-controller reverts live CNP edits within seconds, even with `--field-manager=kustomize-controller`. For an emergency: `flux suspend ks <app> -n <ns>`, hotfix, merge, `flux resume ks <app> -n <ns>`.

## Fan-out audit (all policies)

Inventory with `rg -l 'kind: Cilium(Clusterwide)?NetworkPolicy' kubernetes/apps | sort` (~56 files holding ~90 policies). Split into 5–6 namespace buckets and run one read-only subagent per bucket with the prompt in [reference.md](reference.md). **Re-read every FLAG yourself**; subagents mark nearly everything MINOR and bury the one real break (seasonpackerr had no egress to `download/qbittorrent-gluetun` although its HR targets it). Ship functional fixes in their own PR, bundle hygiene into one, and never let two PRs edit the same CNP file.

## Gotchas & Edge Cases

- **Latent `Valid=False`**: Cilium keeps the last valid revision until an agent restart, then the pod falls to the floor (all syslog dropped once). Check VALID after every apply and after Cilium upgrades.
- **Envoy Gateway doesn't re-translate by itself** after an egress fix. SecurityPolicies stayed `Accepted=False` and proxies served 500s until `kubectl -n network rollout restart deploy/envoy-gateway` (ask first; it's a live change).
- **toFQDNs without `ndots: 1`**: `cilium-dbg fqdn cache list` shows only `*.svc.cluster.local` names. A throwaway test pod can't confirm the fix, because the DNS proxy only records lookups for pods selected by an L7 DNS rule.
- **Don't drop a CIDR because an FQDN seems to cover it**. Dropping NAS `.40` broke the TrueNAS probe.
- **Webhooks on :9443** arrive as `host`/`remote-node` (host-networked apiserver), not only `kube-apiserver` (tuppr, [#480](https://github.com/sp3nx0r/home-ops/pull/480)).
- **Idle apps hide breaks** (seasonpackerr only acts on a Sonarr webhook). "Configured target + no egress rule + default-deny" is proof enough.
- **Dead rules count as findings**: cert-manager `world:53` was a no-op (DoH over 443).
- **Unwanted egress** (Loki analytics to `stats.grafana.org`): disable the feature ([#489](https://github.com/sp3nx0r/home-ops/pull/489)), don't allow it.
- **`egressDeny` precedent** for blocking one destination inside a broad allow: `kubescape/kubescape-operator/app/ciliumnetworkpolicy.yaml`.
- **Pods no CNP selects** (CronJob/maintenance pods with different labels) get only DNS egress.
- **Stale checkout**: fetch and compare live `kubectl get cnp -o yaml` with `git show origin/main:<path>`. A CNP live for minutes (`--sort-by=.metadata.creationTimestamp`) points at what just rolled out.

## Output Template

```
PR: [#<n>](https://github.com/sp3nx0r/home-ops/pull/<n>) — <ns>/<apps> CNPs
Callers audited: | caller | path | egress in caller | ingress in server |
Validated: kustomize ✓ · server dry-run ✓
Live: ks Ready ✓ · VALID=True (<n>) · endpoints Enabled/Enabled · drops during <exercised path>: none | <src → dst:port → fix>
Public path: <host> → <code>
Watch later: <infrequent paths>
```
