# Cluster-wide Default-Deny Floor

Runbook for the last step of the default-deny network baseline: two
`CiliumClusterwideNetworkPolicy` (CCNP) resources that flip the cluster from
"per-app opt-in isolation" to "default-deny everywhere, allow-list up."

> **Status: COMPLETE (live since 2026-09-28, #530; closed out 2026-10-01).**
> Both CCNPs are applied and valid. Every non-`kube-system` pod is
> default-deny, and any pod without a per-app allow-list is cut off. Follow-up
> fixes found during the soak: floor ingress widened for cluster infra
> identities (`8d96f417`), UDP peers and flux-operator events (#538), `ndots:1`
> for `toFQDNs` pods (#548), Pocket ID GeoLite2 refresh (#547), volsync
> cache-scrub apiserver access (#546/#556), vector-syslog rule split (#550),
> and the Kyverno namespace (#563).
>
> Close-out check (2026-10-01): all 81 workload endpoints outside `kube-system`
> enforce policy in both directions (`cilium-dbg endpoint list`). There are no
> host-network pods outside `kube-system`, and `HubblePolicyDenied` is not
> firing. The only non-ICMP drops in the last hour were the expected ones:
> Kubescape egress (see [Expected drops](#expected-drops)), Plex NAT-PMP, and
> one transient stale scrape target during a `loki-gateway` rollout.
> `kube-system` stays deferred as a separate follow-up.

## Goal

Isolation used to be opt-in: a pod was only default-deny once _some_ policy
selected it. The floor inverts that — every pod (except the excluded
namespaces) becomes default-deny by default, and the per-app
`CiliumNetworkPolicy` allow-lists we shipped (edge #498, `default` #516,
idp/storage #518, o11y #520, network #521, volsync/cert-manager/flux #523,
media #525, download #531, kyverno #563) provide the exceptions.

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

| Direction | Universal allow                                                        | Rationale                                                                                                                                                                                                              |
| --------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Egress    | kube-dns `:53` UDP/TCP (L7 `matchPattern: "*"`)                        | Every workload needs name resolution; L7 keeps lookups visible to the DNS proxy (and is what makes `toFQDNs` work).                                                                                                    |
| Ingress   | `fromEntities: [host, remote-node, kube-apiserver, health]`, all ports | kubelet probes come from `host`. Cross-node kubelet traffic and cilium-health checks come from `remote-node` / `kube-apiserver` (every node runs the API server) and `health`. Widened from `host` only in `8d96f417`. |

Everything else (in-cluster peers, egress to `kube-apiserver`, `world`, LAN
CIDRs, LB ports) stays denied unless a per-app policy allows it.

Two consequences matter when writing or debugging a per-app policy:

- **Ingress from the node and control-plane identities is already allowed on
  every port.** That includes kube-apiserver → admission webhook calls, so a
  dropped _ingress_ flow from one of those identities isn't caused by the floor.
  Per-app policies still re-state their webhook and probe rules (e.g. tuppr and
  kyverno on 9443) for self-documentation; the overlap is additive and harmless.
- **Egress to the API server is not in the floor.** Any operator, controller or
  Job that talks to Kubernetes needs `toEntities: [kube-apiserver]` on `6443` in
  its own CNP. This is the most common gap: the pod hangs at API-client
  startup, then fails its probes or times out a Helm install.

### Manifests

Home: `kubernetes/apps/kube-system/network-policies/app/`, a cluster-scoped
Flux Kustomization wired from `kube-system/kustomization.yaml`. Both CCNPs are
validated with `kubectl apply --dry-run=server` against the live Cilium CRD.

## Prerequisites

The floor cannot safely cover a namespace until every running pod there is
allow-listed. Live coverage check (via per-endpoint Cilium policy enforcement):

| Namespace / app                              | State                       | Notes                                                                 |
| -------------------------------------------- | --------------------------- | --------------------------------------------------------------------- |
| `download/qbittorrent-gluetun`               | ✅ covered (#531)           | Per-app CNP added; egress scoped to public space (RFC 1918 excepted). |
| `cert-manager/cainjector`, `media/recyclarr` | egress-only (`ingress: []`) | Nothing connects to them; floor ingress-deny is correct.              |
| `default/volsync-test`                       | egress-only                 | Leftover test pod; nothing connects to it. Candidate for cleanup.     |
| everything else with running pods            | ✅ covered                  | Selected by a per-app CNP (both directions).                          |

> Any pod or namespace created after the floor is applied is default-deny
> immediately, so a new app (or a re-enabled 0-replica one) must ship its CNP in
> the same PR. Kyverno's first install (#524) timed out until #563 added one.

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
   `kubernetes/apps/kube-system/network-policies/` (#530, merged 2026-09-28).
3. **Reconcile and watch with Hubble.** Policy drops are in the o11y stack:
    - **Grafana → Network → "Hubble Policy Drops"**: drop rate and top
      `source → destination` pairs (from `hubble_drop_total`, labelled with
      `workload|reserved-identity` context), plus a Loki panel of the individual
      flows.
    - **Loki** (`{source="hubble"}`): every `POLICY_DENIED` flow, written by the
      Cilium dynamic flowlog exporter to `/var/run/cilium/hubble/policy-drops.log`
      on each node and shipped by Vector. Labels: `node`, `direction`,
      `src_namespace`, `dst_namespace`; the line is
      `src -> dst:port proto reason (direction)`. For example:

        ```logql
        {source="hubble", dst_namespace="media"} |= "UDP"
        {source="hubble"} | json | dst_port="6443"
        ```

    - **Alert `HubblePolicyDenied`** (`kube-system/cilium/app/prometheusrule.yaml`)
      fires when a non-ICMP pair keeps dropping for 15 minutes. Excluded pairs:
      Plex's hourly NAT-PMP probe to the node, and all `kubescape/kubevuln` →
      `world` TCP (see [Expected drops](#expected-drops)).

    For live tailing, the `hubble` CLI (installed via mise) watches policy drops
    **across the whole cluster** by pointing it at the relay —
    `cilium hubble port-forward` handles the connection:

    ```sh
    cilium hubble port-forward &                    # relay -> localhost:4245
    hubble observe --verdict DROPPED --follow        # all namespaces, all nodes
    # scope while investigating: --namespace <ns> / --to-label / --port <n>
    ```

    (Fallback without the CLI: `kubectl -n kube-system exec <cilium-pod> -c
 cilium-agent -- hubble observe --server <hubble-relay-clusterIP>:80
 --verdict DROPPED --follow`.)

    **`toFQDNs` needs `ndots: 1`.** CoreDNS runs `autopath`, so under the
    default `ndots:5` the first search-path query (`name.<ns>.svc.cluster.local`)
    is answered with a CNAME and Cilium only records that long name. A
    `matchName`/`matchPattern` rule then never matches, and the traffic shows up
    as a policy drop to a bare `world` IP (or a `world(<name>.<ns>.svc.cluster.local)`
    label in Hubble). Pods with FQDN allow-lists set
    `dnsConfig.options: [{name: ndots, value: "1"}]`: gatus, pocket-id, tuppr,
    and kubescape (through a HelmRelease postRenderer, since the chart has no
    `dnsConfig` value).

    Optionally bisect: apply `default-deny-ingress` first, soak, then
    `default-deny-egress`. Either CCNP can be removed independently to restore
    that direction instantly.

4. **Soak + close out.** ✅ Done 2026-10-01: runbook moved to `docs/completed/`,
   finding #1 marked Resolved in `security-review-and-hardening-plan.md`.

### Expected drops

These show up in Hubble/Loki and are intended:

- **qbittorrent ICMP** — `<world> -> media/qbittorrent ... ICMPv4
DestinationUnreachable` (and the occasional `TTLExceeded`): unsolicited ICMP
  error replies from external BitTorrent peers, which the ingress floor is
  _supposed_ to drop. Actual BitTorrent on `:50413` is unaffected. Filter with
  `hubble observe --verdict DROPPED --follow | grep -v ICMP`.
- **Plex NAT-PMP** — `media/plex -> reserved:host :5351/UDP`, hourly.
- **Kubescape phone-home and unlisted registries** — `kubescape/node-agent ->
api.armosec.io` (ARMO cloud, intentionally not allowed) and
  `kubescape/kubevuln -> <registry>:443` (e.g. `reg.kyverno.io`). kubevuln's
  CNP allows only `grype.anchore.io`, because SBOMs come from the node-agent,
  so registry lookups are expected to drop. The alert ignores all kubevuln →
  `world` TCP, so a _new_ kubevuln egress need won't alert. Check Loki if
  vulnerability scans look incomplete.
- **Transient stale scrape targets** — `prometheus -> reserved:world <pod-ip>`
  for a few minutes after a pod is replaced, while Prometheus still scrapes the
  old IP (which no longer has an identity).

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
etcd/controller-manager/scheduler `0.0.0.0` metric binds are no longer reachable
from pods, since the floor denies arbitrary pod→control-plane traffic. They are
still reachable from the LAN because they're host-network listeners. That part
is S1 (Talos host firewall, draft #558).
