# Cluster-wide Default-Deny Floor (Finding #1 finale)

Runbook for the last step of the default-deny network baseline: two
`CiliumClusterwideNetworkPolicy` (CCNP) resources that flip the cluster from
"per-app opt-in isolation" to "default-deny everywhere, allow-list up."

> **Status: READY.** The floor makes every selected pod default-deny; any pod
> without a per-app allow-list is cut off. A live coverage sweep confirms every
> running non-`kube-system` pod is policy-enforced (`download/qbittorrent-gluetun`
> was the last gap, closed by #531). See [Prerequisites](#prerequisites).

## Goal

Isolation used to be opt-in: a pod was only default-deny once _some_ policy
selected it. The floor inverts that — every pod (except the excluded
namespaces) becomes default-deny by default, and the per-app
`CiliumNetworkPolicy` allow-lists we shipped (edge #498, `default` #516,
idp/storage #518, o11y #520, network #521, volsync/cert-manager/flux #523,
media #525) provide the exceptions.

## Design

Two CCNPs, **split by direction** so they can be enabled and bisected
independently. Both select _every pod except the excluded namespaces_ and grant
only the universal baseline; everything else must come from a per-app policy.

Why exclude `kube-system`: it holds cluster DNS, the CNI, CSI, and other infra
whose exceptions belong in a purpose-built policy, not a blanket floor. It is
handled in [kube-system](#kube-system-deferred) as a separate follow-up.

There are **no host-networked pods outside `kube-system`** today, so nothing
else escapes the selector via host identity.

### Baseline grants

| Direction | Universal allow                                 | Rationale                                                                        |
| --------- | ----------------------------------------------- | -------------------------------------------------------------------------------- |
| Egress    | kube-dns `:53` UDP/TCP (L7 `matchPattern: "*"`) | Every workload needs name resolution; L7 keeps lookups visible to the DNS proxy. |
| Ingress   | `fromEntities: host`                            | kubelet `httpGet`/`tcpSocket` probes originate from the local node.              |

Everything else (in-cluster peers, `kube-apiserver`, `world`, LAN CIDRs, LB
ports) stays denied unless a per-app policy allows it. The existing per-app
policies already re-state DNS + host-probe rules; that overlap is additive and
harmless, and future per-app policies may rely on this baseline instead of
repeating it.

### Manifests

Home: `kubernetes/apps/kube-system/network-policies/app/`, a cluster-scoped
Flux Kustomization wired from `kube-system/kustomization.yaml`. Both CCNPs are
validated with `kubectl apply --dry-run=server` against the live Cilium CRD.

## Prerequisites

The floor cannot safely cover a namespace until every running pod there is
allow-listed. Live coverage check (via per-endpoint Cilium policy enforcement):

| Namespace / app                                                                    | State                       | Notes                                                                 |
| ---------------------------------------------------------------------------------- | --------------------------- | --------------------------------------------------------------------- |
| `download/qbittorrent-gluetun`                                                     | ✅ covered (#531)           | Per-app CNP added; egress scoped to public space (RFC 1918 excepted). |
| `cert-manager/cainjector`, `media/recyclarr`                                       | egress-only (`ingress: []`) | Nothing connects to them; floor ingress-deny is correct.              |
| `default/volsync-test`                                                             | egress-only                 | Leftover test pod; nothing connects to it. Candidate for cleanup.     |
| everything else with running pods                                                  | ✅ covered                  | Selected by a per-app CNP (both directions).                          |
| `external-secrets`, `o11y/alert-to-zeroclaw`, `default/*-proxy`, `kasm-workspaces` | ⚠️ 0 pods                   | Latent traps: re-enabling one without a CNP will silently isolate it. |

> Any pod created after the floor is applied is default-deny immediately — so
> the 0-pod entries above are latent traps.

## kube-system (deferred)

`kube-system` is intentionally out of the floor's selector. Hardening it later
needs care: `coredns` is a normal pod (policyable, but a wrong rule breaks _all_
DNS), while `cilium`, `node-exporter`, and friends are host-networked (CNP does
not apply to their host identity). Treat as its own follow-up with explicit
carve-outs (DNS, apiserver, CSI, spegel), not part of this floor.

## Rollout

1. **Land all per-app coverage first.** Done for every namespace with running
   pods (`download` closed by #531).
2. **Materialize + wire** the manifests under
   `kubernetes/apps/kube-system/network-policies/` (this PR).
3. **Reconcile and watch with Hubble.** Hubble is now enabled — observe drops
   from inside a Cilium agent against the relay:
    ```sh
    CIL=$(kubectl -n kube-system get pod -l k8s-app=cilium -o name | head -1 | cut -d/ -f2)
    RELAY=$(kubectl -n kube-system get svc hubble-relay -o jsonpath='{.spec.clusterIP}')
    kubectl -n kube-system exec "$CIL" -c cilium-agent -- \
      hubble observe --server "$RELAY":80 --verdict DROPPED --follow
    ```
    Optionally bisect: apply `default-deny-ingress` first, soak, then
    `default-deny-egress`. Either CCNP can be removed independently to restore
    that direction instantly.
4. **Soak + close out.** Once clean, move this runbook to `docs/completed/` and
   mark finding #1 Resolved.

### Rollback

Each CCNP is independent and cluster-scoped — delete the offending one to
instantly restore that direction:

```sh
kubectl delete ciliumclusterwidenetworkpolicy default-deny-egress   # or -ingress
```

Via GitOps, drop the resource from the kustomization and reconcile. Because the
two directions are separate policies, a bad egress rule never forces reverting
ingress isolation (and vice-versa).

## Absorbs residual #10 items

With the floor in place, the leftover #10 exposures collapse into
Prometheus-only reachability: `volsync` `metrics.disableAuth: true` is scoped by
the volsync CNP's Prometheus-only ingress (#523), and the
etcd/controller-manager/scheduler `0.0.0.0` metric binds are only reachable from
`kube-system`/host once the floor denies arbitrary pod→control-plane traffic.
