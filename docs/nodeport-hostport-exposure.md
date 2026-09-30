# NodePort / hostPort LAN Exposure

Follow-up to the Talos host firewall plan (`talos-host-firewall-plan.md`, PR
[#558](https://github.com/sp3nx0r/home-ops/pull/558)). Cilium's
kube-proxy replacement serves NodePorts and hostPorts in eBPF at tc ingress,
**before netfilter**, so the Talos firewall cannot filter them
([siderolabs/talos#12955](https://github.com/siderolabs/talos/issues/12955)).
Before this change, every node IP and the `192.168.5.254` VIP exposed the
following to the whole LAN:

- An auto-allocated NodePort for each of the 8 LoadBalancer Services (17
  ports).
- Spegel's unauthenticated registry mirror on hostPort `29999` and NodePort
  `30021`.

## Changes

- **`allocateLoadBalancerNodePorts: false` on every LoadBalancer Service:**
    - app-template values: `plex`, `qbittorrent-bittorrent`, `tor-relay-app`,
      `minecraft-bedrock`.
    - `EnvoyProxy.spec.provider.kubernetes.envoyService`: covers
      `envoy-external` and `envoy-internal`.
    - A Flux `postRenderers` JSON patch for `vector-syslog` and `k8s-gateway`,
      whose charts have no value for it.
    - `download/qbittorrent-gluetun` has no LoadBalancer. `opencanary` on the
      `feat/canarytokens` branch is out of scope and needs the same flag when it
      lands.
- **`kube-system/spegel` CiliumNetworkPolicy (ingress only):**
    - registry `:5000` from `host`, `remote-node` and `kube-apiserver` (the
      identity peer nodes carry on this hyper-converged cluster)
    - `:5000` and `:5001` TCP/UDP between Spegel pods
    - `:9090` from Prometheus
    - Egress stays open, since kube-system is outside the cluster-wide floor.

## Why this is safe

- **Cilium doesn't need NodePorts.** Cilium LB-IPAM and L2 announcements put
  the LoadBalancer IP straight into the eBPF service map, and KPR forwards LB
  IP → backend without a NodePort. The Cilium docs show
  `allocateLoadBalancerNodePorts: false` as a supported configuration
  ([kube-proxy free: selective service type exposure][cilium-kpr]).
  Kubernetes documents the field as meant for "load balancer implementations
  that route traffic directly to pods" ([Service docs][k8s-svc]).
- **Spegel can't simply become ClusterIP.** containerd runs in the host
  namespace and its mirror config (`/etc/cri/conf.d/hosts/_default/hosts.toml`,
  written by Spegel) lists `http://<nodeIP>:29999` (hostPort) and
  `http://<nodeIP>:30021` (NodePort fallback to peers). The chart hardcodes
  `type: NodePort` and always adds the NodePort mirror target. Switching to
  `usePreferSameNodeTrafficDistribution` only swaps the hostPort for the same
  NodePort.
- **A pod-level policy does work for Spegel.** Cilium enforces the endpoint's
  ingress policy _after_ service/hostPort translation, using the original
  client identity. Live check: syslog from the NAS reaches `vector-syslog`
  through LB `.24` as `cidr:192.168.5.40/32,reserved:world`. With DSR
  (`bpf-lb-mode: dsr`) the client IP survives even when the backend is on
  another node. So a LAN client hitting `nodeIP:29999/30021` is `world` and
  gets denied.
- **The allowed sources match what Hubble shows.** Live flows to Spegel were
  `reserved:host,reserved:kube-apiserver → 5000` (containerd through
  socket-LB, and readiness probes), `spegel → spegel 5001`, and
  `prometheus → 9090`. Identity 7 (`kube-apiserver`) also carries
  `reserved:remote-node`, which covers NodePort-fallback pulls from peer
  nodes.

## What remains

- **The KPR NodePort range stays enabled.** It's needed for Spegel's `30021`,
  the only NodePort-type Service. It holds no sockets; entries exist only for
  allocated Service ports. After this change the range serves only
  `spegel-registry` 30021 (policy-protected) and Plex's `healthCheckNodePort` 30577. That port is required by `externalTrafficPolicy: Local`, isn't
  affected by this flag, and is a real `cilium-agent` socket, so the Talos
  firewall in #558 blocks it.
- **Other hostPorts** (Cilium agent/operator, node-exporter) belong to
  `hostNetwork` pods. They're real host sockets and are covered by the Talos
  firewall, not eBPF.
- **Leftover NodePorts carry little risk.** Until they're removed, or if a
  future LoadBalancer omits the flag, a NodePort only reaches the _same pod_
  as its LB IP. Per-app CNPs and the floor apply after translation, and the
  LB-facing policies already admit LAN/world on those ports. So this is "same
  pod, different address", not a new trust boundary.
- **SNAT caveat.** If Cilium ever moves off DSR (`loadBalancer.mode: snat`),
  LAN → `nodeX:30021` → Spegel on `nodeY` would arrive as `remote-node` and be
  allowed. The hostPort path stays local and is unaffected.
- **Follow-up:** a Kyverno policy (finding S7) requiring
  `allocateLoadBalancerNodePorts: false` on new LoadBalancer Services.

## Rollout

Kubernetes does **not** release NodePorts that are already allocated when the
flag flips to `false`. The Service docs say "You must explicitly remove the
nodePorts entry in every Service port". Helm (helm-controller) and Envoy
Gateway both server-side-apply these Services, and no field manager owns
`nodePort`, so applying doesn't remove it either. A server-side dry-run on
`media/plex` confirmed this:

- Setting the flag alone leaves nodePort `32566` in place.
- Removing `nodePort` once the flag is `false` leaves it unset.
- Removing it while the flag is still `true` just re-allocates it.

1. **Pre-check.** Make sure no UniFi port forward targets a node IP plus a
   NodePort. They must point at the LB IPs: tor-relay `.22`, minecraft `.25`,
   Plex `.21`, and qBittorrent `.23`.
2. **Merge and let Flux reconcile.** Confirm every LoadBalancer reports
   `false`:

    ```sh
    kubectl get svc -A -o json | jq -r '.items[] | select(.spec.type=="LoadBalancer")
      | "\(.metadata.namespace)/\(.metadata.name) alloc=\(.spec.allocateLoadBalancerNodePorts) np=\([.spec.ports[].nodePort])"'
    ```

3. **Release the old NodePorts.** Run once with `--dry-run=server`, then
   without it:

    ```sh
    kubectl get svc -A -o json | jq -c '.items[]
      | select(.spec.type=="LoadBalancer" and .spec.allocateLoadBalancerNodePorts==false)
      | {ns: .metadata.namespace, name: .metadata.name,
         ops: [.spec.ports | to_entries[] | select(.value.nodePort) | {op: "remove", path: "/spec/ports/\(.key)/nodePort"}]}
      | select(.ops | length > 0)' |
    while read -r s; do
      kubectl -n "$(jq -r .ns <<<"$s")" patch svc "$(jq -r .name <<<"$s")" \
        --type=json -p "$(jq -c .ops <<<"$s")" --dry-run=server \
        -o jsonpath='{.metadata.namespace}/{.metadata.name} {.spec.ports[*].nodePort}{"\n"}'
    done
    ```

    This only changes Service ports; the LB IP frontends and existing
    connections are untouched. If Envoy Gateway's reconcile ever brings them
    back, step 2 will show it.

4. **Verify.**
    - Re-run step 2. Every `np` should be `[null]`.
    - From a LAN host, `nc -zv -w3 192.168.5.51 <old nodePort>` should fail.
    - The LB IPs should still answer:
      `curl -sk https://192.168.5.10`, `curl -sk https://192.168.5.20`,
      `curl -s http://192.168.5.21:32400/identity`,
      `dig @192.168.5.2 echo.<domain>`, and `nc -zv 192.168.5.23 50413`.
      Send `logger -n 192.168.5.24 -P 514 -d fw-test`, then check Loki for it.
      Test minecraft UDP `.25` from a client.
5. **Verify Spegel.**
    - From a LAN host, `curl -m3 http://192.168.5.51:29999/v2/` and `:30021/v2/`
      should time out (policy drop).
    - In Hubble, `hubble observe --to-label app.kubernetes.io/name=spegel --verdict DROPPED`
      should show only `world` sources.
    - Pulls should keep hitting the mirror: `spegel_mirror_requests_total`
      should keep increasing when a pod with a cached image is scheduled.
    - The Prometheus target `up{job=~".*spegel.*"}` should be `1`.
    - If Spegel breaks, containerd falls back to the upstream registry, so pulls
      get slower but don't fail.

**Rollback:** revert the commit. With the flag back to `true`, the next apply
re-allocates NodePorts. Deleting the `spegel` CNP restores open ingress
immediately.

[cilium-kpr]: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
[k8s-svc]: https://kubernetes.io/docs/concepts/services-networking/service/#load-balancer-nodeport-allocation
