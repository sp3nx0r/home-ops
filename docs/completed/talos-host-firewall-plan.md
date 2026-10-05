# Talos Host Ingress Firewall

> **Status: COMPLETE (applied to all three nodes 2026-10-05, #558).** Every
> node runs the default-block `ingress` chain, `topf apply --dry-run` shows no
> pending diff, and the NodePort/hostPort residual was closed by #562 (see
> `nodeport-hostport-exposure.md`). See [Rollout record](#rollout-record-2026-10-05).

Closes finding **S1** in `sre-and-security-evaluation.md` and the residual **#10**
item in `security-review-and-hardening-plan.md` (etcd / controller-manager /
scheduler metric listeners bound to `0.0.0.0`).

Config: `talos/all/80-firewall.yaml` (default action + rules shared by every
node) and `talos/control-plane/80-firewall.yaml` (control-plane-only services).
topf picks both up automatically: it merges every file in `all/` and
`<role>/` in lexical order, so no `topf.yaml` change is needed. The rendered diff
is purely additive (9 new documents per node), and `topf apply --dry-run`
reports that it applies **without a reboot**.

## Why

Talos has no host firewall today (no `NetworkDefaultActionConfig` or
`NetworkRuleConfig`). Any host on the LAN, including routed VLANs, can
open a TCP connection to:

- **apid 50000 / trustd 50001.** These use mTLS, so an open port does not give
  access, but it is still pre-auth attack surface.
- **kubelet 10250.** Authenticated, but it's the highest-value node API.
- **etcd 2379/2380/2383.** mTLS.
- **etcd metrics 2381.** Plaintext HTTP with no auth, on `0.0.0.0`.
- **kube-controller-manager 10257 / kube-scheduler 10259.** Bound to `0.0.0.0`.
- **node-exporter 9100, Cilium metrics 9962–9965, Hubble 4244,
  cilium-health 4240.** No auth.
- **rpcbind 111 and rpc.statd (random ports).** These come from the NFS client
  and aren't needed with NFSv4.2.
- **Cilium's kube-proxy healthz (10256) and the Plex `healthCheckNodePort`
  listener (30577).**

`CiliumNetworkPolicy` and the cluster-wide policy floor only cover pod
endpoints. Host-network listeners are outside their scope while the Cilium host
firewall is disabled. So the node firewall is the only control for these
ports.

## Research findings

### Talos Ingress Firewall (v1.14)

Sources: [Talos v1.14 Ingress Firewall docs][talos-fw];
[`nftables_chain_config.go` @ v1.14.1][talos-src].

- `NetworkDefaultActionConfig` sets `ingress: block` or `accept`. Each
  `NetworkRuleConfig` document has a unique `name`, a `portSelector`
  (`ports` list or ranges, one `protocol`: `tcp` or `udp`), and `ingress`
  source subnets with an optional `except`. Rules match on **source subnet and
  destination port only**. They can't match on destination address or
  interface, and ICMP rules aren't supported ([#14070][t14070]).
- Talos builds an `inet talos` table with **two** chains:
    - `ingress` (hook `input`, priority mangle+10, policy drop in block mode).
      It accepts `lo`/`siderolink`/`kubespan`, `ct established,related`, and
      ICMP/ICMPv6 rate-limited to 5 pkt/s (after dropping timestamp and
      address-mask types). It also accepts **pod/service CIDR → pod/service
      CIDR** and **pod/service CIDR → host DNS (169.254.116.108:53)**, because
      `forwardKubeDNSToHost: true`. The user rules come after these.
    - `prerouting` (hook `prerouting`, priority dstnat−10). This one only acts
      on packets addressed to the node's own addresses (`routed-no-k8s`, which
      here is the node IP plus the `192.168.5.254` VIP). It drops `ct state new`
      TCP/UDP that no rule allows, so kube-proxy-style iptables DNAT can't
      bypass the input filter.
- The docs' recommended control-plane set is: apid and 6443 open,
  kubelet and trustd from the cluster, etcd from the control-plane nodes, and
  the CNI's VXLAN port from the cluster. Cilium's own requirements are TCP
  4240 and ICMP between nodes for health, 4244 for Hubble, 9962–9964 for
  metrics, and UDP 8472 only for VXLAN ([Cilium firewall rules][cilium-fw]).
- Talos doesn't log dropped packets. The only feedback is broken connections,
  which is why the rollout below relies on `--mode=try` plus explicit checks.

### Live cluster facts (read-only checks, 2026-09-30)

- Cilium 1.20.2, `routing-mode: native`, `auto-direct-node-routes`, no
  VXLAN/Geneve device on the nodes. `tunnel-protocol: vxlan` is only the unused
  default. **No UDP 8472/6081 rule is needed.**
- KPR is on in `DSR` mode with `DSR Dispatch Mode: IP Option/Extension`, so
  there's no extra encapsulation port. Socket LB is on (host-namespace only).
  `hostLegacyRouting: true`, BPF masquerade, host firewall **disabled**.
- **Pod → node traffic isn't masqueraded.** The Cilium NAT table on `miirym` only
  holds entries for off-cluster hosts (e.g. `192.168.5.70`), and CT entries show
  `10.42.0.184` (Prometheus) connecting directly to `192.168.5.5x:2381/10250/
10257/10259/9100/9962/9965`. **Scrapes arrive from the pod IP, so rules must
  allow `10.42.0.0/16`, not just the node IPs.** Talos' built-in pod↔pod accept
  doesn't cover this because the destination is a node IP.
- Established inbound connections, grouped by port:

    | Port                                             | Sources seen                                           |
    | ------------------------------------------------ | ------------------------------------------------------ |
    | 50000                                            | nodes, `192.168.5.181`                                 |
    | 6443                                             | nodes, VIP, pods, `192.168.5.181`, `::1`               |
    | 10250                                            | nodes (kube-apiserver), Prometheus, metrics-server pod |
    | 2380                                             | nodes                                                  |
    | 4240                                             | nodes                                                  |
    | 4244                                             | hubble-relay pod                                       |
    | 2381 / 10257 / 10259 / 9100 / 9962 / 9963 / 9965 | Prometheus pod                                         |

- **kube-apiserver audit logs (30 days, Loki):** the only non-node, non-pod
  source is **`192.168.5.181`**, the admin workstation.
- NFS mounts are all `vers=4.2`, so rpcbind/statd need no inbound access. The
  NUT client polls `192.168.5.40:3493` outbound, and iSCSI is outbound too.

### Cilium interaction

LoadBalancer IPs, NodePorts, hostPorts and DSR don't reach the Talos firewall.
Cilium's `bpf_host` program at tc ingress on `enp5s0f0np0` runs **before
netfilter**. It DNATs service traffic to the backend pod IP and either delivers
it locally or forwards it natively to the backend node ([Cilium KPR
docs][cilium-kpr]). By the time the packet reaches netfilter, the destination
is a pod IP. That means the `prerouting` chain accepts it as "not addressed to
me", and it goes through `forward`, which Talos doesn't filter, rather than
`input`. A Talos maintainer confirmed this in [#12955][t12955] ("If you use
Cilium to terminate traffic to these ports … the packets might never reach
the firewall").

- **L2 announcements.** The LB IPs `.2 .10 .20–.25` are answered via ARP. ARP
  isn't IP, so the `inet` table doesn't touch it. The LB IPs aren't assigned to
  the node, so they aren't in the `prerouting` "my addresses" set.
- **DSR.** The backend node receives packets addressed to the pod with an IP
  option, and the reply leaves the backend directly. Neither side hits
  `input`.
- **Spegel.** The containerd mirror config dials the node's own IP
  (`192.168.5.5x:29999` and NodePort `:30021`, per
  `/etc/cri/conf.d/hosts/_default/hosts.toml`). Host-namespace socket LB
  rewrites that at `connect()` to a Spegel pod IP, so it never needs a rule.
- **BPF masquerade replies.** Replies to pod→external connections come back to
  the node IP. `bpf_host` reverse-SNATs them to the pod IP before netfilter.
  The kernel conntrack never saw these flows, so this relies on Cilium handling
  them first. It's checked explicitly during rollout (no off-cluster
  Prometheus target down, Flux source fetches).
- **DNS proxy (the case that needed checking).** All ~90 policies with
  `rules.dns` send pod DNS through Cilium's transparent DNS proxy. L7
  redirection uses iptables `TPROXY` ([Cilium requirements][cilium-fw]), so
  these packets **do** traverse `input`, with the original destination.
  Every DNS rule in the cluster targets the `kube-system/kube-dns` endpoints,
  so the packets are pod IP → pod IP and Talos' built-in pod↔pod accept
  admits them. CoreDNS forwards to host DNS `169.254.116.108`, which is also
  built-in. If a policy ever allows DNS to a resolver outside the cluster with
  L7 `rules.dns` (for example `toCIDR: 1.1.1.1/32`), those proxied packets
  would be dropped. Fix that with a `tcp`/`udp` 53 rule from `10.42.0.0/16`
  (nothing on the host listens on :53 on the node IP, so the rule is harmless).
- **cilium-health.** This probes remote node IPs with ICMP and TCP 4240 (and
  health-endpoint pod IPs over `forward`). ICMP is within Talos' 5 pkt/s
  built-in allowance. TCP 4240 is allowed from the nodes.
- **Cilium host firewall** stays off. The Talos docs warn that the two would
  fight over precedence.

### Residual exposure the host firewall cannot close

For the same eBPF reason, **NodePorts and hostPorts on node IPs stay reachable
from the LAN** (the VIP turned out not to answer on them). That covers every
LoadBalancer Service's auto-allocated NodePort, `spegel-registry` 30021, and
Spegel hostPort 29999. The Spegel ports are unauthenticated registry mirrors of
images already in the cache.

**Closed by #562 and #616 (2026-10-05):** every LoadBalancer Service sets
`allocateLoadBalancerNodePorts: false` and the old NodePorts were released, a
`kube-system/spegel` CiliumNetworkPolicy denies LAN clients on 29999/30021, and
the Kyverno policy `require-lb-no-nodeports` denies new LoadBalancers that
allocate NodePorts. Details in `nodeport-hostport-exposure.md`.

### Why not narrow the `0.0.0.0` metric binds instead

Prometheus scrapes etcd, controller-manager and scheduler on the **node IP**
(the `kubeEtcd` Service selects the kube-apiserver static pods, so its
endpoints are node IPs). The node IP is the LAN-facing address. Binding to it
instead of `0.0.0.0` would only drop IPv6 and the `cilium_host` address, and
would not reduce LAN exposure. The only exposure-reducing bind is `127.0.0.1`,
which breaks scraping. So the firewall rule
`control-plane-metrics-ingress` (2381/10257/10259 from the pod CIDR only) is
the real control. `control-plane/00-cluster.yaml` is left untouched. It would
also need per-node templating (`.tpl`), and other branches edit that file.

## Decisions

- **apid is open to all of `192.168.5.0/24`**, plus the pod CIDR. apid
  requires mTLS client certificates from the talosconfig, so an open port
  grants nothing without them. Pinning the admin workstation (`192.168.5.181`
  today) would risk a lockout whenever its IP changes or a new workstation
  replaces it. Other VLANs and VPN clients stay blocked.
- **kube-apiserver 6443 stays open to all of `192.168.5.0/24`**, plus the pod
  CIDR. It's authenticated (certs/OIDC), and LAN kubectl clients shouldn't
  need firewall edits.

## Port matrix

Node set = `192.168.5.50/32`, `.51/32`, `.52/32`. Pods = `10.42.0.0/16`.

| Port(s)/proto                                                                                                                      | Service                                           | Who needs it                                                                 | Allowed sources                               | Rule                                 |
| ---------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------- | ------------------------------------ |
| 50000/tcp                                                                                                                          | apid                                              | admin workstation, apid proxying between nodes, tuppr (in-cluster Talos API) | `192.168.5.0/24`, pods                        | `apid-ingress`                       |
| 50001/tcp                                                                                                                          | trustd                                            | nodes joining or renewing certs                                              | nodes                                         | `trustd-ingress` (CP)                |
| 6443/tcp                                                                                                                           | kube-apiserver                                    | workstation and LAN kubectl, nodes, VIP, pods via `kubernetes` Service       | `192.168.5.0/24`, pods                        | `kube-apiserver-ingress` (CP)        |
| 2379-2380, 2383/tcp                                                                                                                | etcd client, peer, client-HTTP                    | control-plane nodes                                                          | nodes                                         | `etcd-ingress` (CP)                  |
| 2381/tcp                                                                                                                           | etcd metrics (plaintext)                          | Prometheus                                                                   | pods                                          | `control-plane-metrics-ingress` (CP) |
| 10257/tcp                                                                                                                          | kube-controller-manager                           | Prometheus                                                                   | pods                                          | `control-plane-metrics-ingress` (CP) |
| 10259/tcp                                                                                                                          | kube-scheduler                                    | Prometheus                                                                   | pods                                          | `control-plane-metrics-ingress` (CP) |
| 10250/tcp                                                                                                                          | kubelet                                           | kube-apiserver (node IPs), Prometheus, metrics-server                        | nodes, pods                                   | `kubelet-ingress`                    |
| 4240/tcp                                                                                                                           | cilium-health                                     | Cilium agents on other nodes                                                 | nodes, pods                                   | `cilium-ingress`                     |
| 4244/tcp                                                                                                                           | Hubble peer API                                   | hubble-relay                                                                 | nodes, pods                                   | `cilium-ingress`                     |
| 9100/tcp                                                                                                                           | node-exporter                                     | Prometheus                                                                   | pods                                          | `node-metrics-ingress`               |
| 9962-9965/tcp                                                                                                                      | Cilium agent, operator, envoy, and Hubble metrics | Prometheus                                                                   | pods                                          | `node-metrics-ingress`               |
| ICMP / ICMPv6                                                                                                                      | cilium-health, PMTU                               | nodes                                                                        | any (Talos built-in, 5 pkt/s)                 | built-in                             |
| pods ↔ pods/services, pods → 169.254.116.108:53                                                                                    | DNS proxy, pod traffic that hits `input`          | pods                                                                         | pod/service CIDRs                             | built-in                             |
| LB IPs, NodePorts, hostPorts (29999, 30000–32767)                                                                                  | Cilium eBPF                                       | LAN clients                                                                  | not filtered by Talos (eBPF before netfilter) | n/a                                  |
| **blocked:** 111 (rpcbind), rpc.statd ephemeral, 10256 (KPR healthz), 30577 (Plex `healthCheckNodePort` listener), everything else |                                                   | nobody (no external LB or NFSv3)                                             | none                                          | default `block`                      |

## Rollout

This is an apply-time change only (no reboot). Do **one node at a time**, and
never proceed while any node is unhealthy. `topf apply --mode try` has no
timeout flag, and Talos' default rollback timeout is 1 minute, which is too
short for the checks. So render with topf and use `talosctl` directly for the
try step.

Order: do the node holding the **active VIP** (`192.168.5.254`) **last**. The
VIP moves between control-plane nodes, so check which node has it at rollout
time (pre-flight below); the other two nodes can go in either order.

```sh
# Pre-flight (from an admin host on 192.168.5.0/24)
ip -4 addr | grep 192.168.5.             # apid and 6443 are allowed from this subnet only
talosctl -n 192.168.5.50,192.168.5.51,192.168.5.52 get addresses | grep 192.168.5.254   # VIP holder: do it last
talosctl -n 192.168.5.50,192.168.5.51,192.168.5.52 etcd status
kubectl get nodes; kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status | grep 'Cluster health'
just talos diff                          # expect only the 9 new documents per node

umask 077; just talos render             # -> talos/rendered/<node>.yaml (gitignored, contains secrets)
```

For each node (for example `NODE=aurinax IP=192.168.5.52`):

```sh
talosctl -n $IP apply-config -f talos/rendered/$NODE.yaml --mode try --timeout 10m
```

Within the 10-minute window, run every check below with **new** connections.
Existing sessions survive because `ct established` is accepted.

1. **Talos API.** Run `talosctl -n $IP version` directly, and through a peer
   with `talosctl -e 192.168.5.50 -n $IP version`. Run
   `talosctl -n $IP get nftableschains`; the `ingress` and `prerouting` chains
   should be present.
2. **Negative tests from the workstation.** These should time out:
   `nc -zv -w3 $IP 2381`, `nc -zv -w3 $IP 10250`, `nc -zv -w3 $IP 111`,
   `nc -zv -w3 $IP 9100`. These should succeed: `nc -zv -w3 $IP 6443` and
   `nc -zv -w3 $IP 50000`.
3. **etcd.** `talosctl -n $IP etcd status` and `talosctl -n $IP etcd members`
   should show 3 members, all started, with no alarms.
   `talosctl -n $IP service etcd` should report `Running`/`OK`.
4. **kubelet.** `kubectl get node $NODE` should be `Ready`. Run
   `kubectl logs` on any pod on `$NODE`, which goes apiserver→kubelet over 10250. `kubectl top node $NODE` checks metrics-server→kubelet.
5. **Prometheus targets.** Wait at least two scrape intervals (about 1
   minute), then run
   `kubectl -n o11y port-forward svc/kube-prometheus-stack-prometheus 9090` and
   `curl -s localhost:9090/api/v1/query --data-urlencode "query=up{instance=~\"$IP:.*\"}" | jq '.data.result[]|[.metric.job,.value[1]]'`.
   Every job should be `1`: kubelet (plus cadvisor/probes), node-exporter,
   kube-etcd, kube-controller-manager, kube-scheduler, apiserver,
   cilium-agent, hubble, and cilium-operator on whichever node runs it. Also
   check that `up == 0` is empty cluster-wide; off-cluster targets exercise the
   BPF-masquerade reply path. (No target carries an `instance` label of
   `192.168.5.70:*`, so filtering on that returns nothing.)
6. **Cilium.** Run
   `kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --verbose | sed -n '/Cluster health/,/Modules/p'`
   from an agent on a _different_ node. It should show `3/3 reachable`, with
   `$IP` host ICMP and HTTP `OK`. Then run
   `kubectl -n kube-system logs deploy/hubble-relay --since=5m | grep -iE 'unavailable|refused|timeout'`,
   which should print nothing.
7. **DNS through the proxy.** Run
   `kubectl -n default exec deploy/searxng -- getent hosts github.com` against
   a pod on `$NODE` (pick one with `kubectl get pods -A -o wide --field-selector spec.nodeName=$NODE`).
   No new `POLICY_DENIED` or `DNS` drops should appear in Loki
   `{source="hubble"}`.
8. **LB IPs.** Check the L2 lease holders with
   `kubectl -n kube-system get lease | grep cilium-l2announce`. Test LB IPs
   that `$NODE` answers for, or whose backends run on it, from a LAN host:
    - `curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.5.10` (envoy-internal)
    - `curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.5.20` (envoy-external)
    - `curl -s http://192.168.5.21:32400/identity` (Plex)
    - `dig @192.168.5.2 echo.${SECRET_DOMAIN}` (k8s-gateway)
    - `nc -zv 192.168.5.23 50413` (qBittorrent)
    - `logger -n 192.168.5.24 -P 514 -d "fw-test-$NODE-$(date +%s)"`, then
      confirm the line reaches Loki with `{source="syslog"} |= "fw-test"`
      (vector-syslog, UDP 514)
9. **Spegel.** `kubectl -n kube-system logs -l app.kubernetes.io/name=spegel --since=10m | grep -iE 'error|fail'`
   should print nothing new. Optionally schedule a pod with an
   already-cached image on `$NODE` and confirm it pulls instantly.
10. **Tuppr (in-cluster Talos API).**
    `kubectl -n system-upgrade logs deploy/tuppr --since=10m | grep -iE 'talos|50000|error'`
    should show no connection errors.

If **any** check fails, do nothing: the node reverts on its own when the
10-minute timer expires, whether or not it's reachable. Confirm with
`talosctl -n $IP get nftableschains`, which should list no chains. If all
checks pass, **let the try timer expire** (confirm the chains are gone), then
make the config permanent through the normal diff-and-confirm path:

```sh
just talos apply-node $NODE no-reboot    # topf shows the same 9-document diff; confirm
```

Re-run checks 1, 3, 5 and 6, then soak for about 30 minutes (watch Alertmanager)
before moving to the next node. After all three nodes are done, run
`rm -rf talos/rendered`.

Letting the try window expire before the permanent apply is deliberate.
During `try`, the running config already contains the rules, so
`topf`'s diff would be empty. Waiting for the revert keeps the permanent step
the same reviewed diff.

`topf apply` prompts for confirmation, so the recipe needs an interactive
terminal. From a non-interactive shell, review the per-node
`topf apply --nodes-filter "^$NODE$" --dry-run` output, then run
`topf apply --nodes-filter "^$NODE$" --mode no-reboot --confirm=false`.

## Rollout record (2026-10-05)

- **Order:** aurinax (.52), miirym (.50, cilium-operator), then palarandusk
  (.51), which held the VIP and ran Prometheus, hubble-relay and
  metrics-server.
- **Per node:** `--mode try --timeout 10m`. All ten checks passed while the
  rules were active, and Cilium host probes taken after the apply were `OK`.
  Each node reverted cleanly (no chains). The permanent apply was the same
  9-document, additive-only diff with no reboot, followed by a re-check and a
  30-minute soak.
- **From the workstation on every node:** 2381, 10250, 10257, 4240, 9100 and
  111 are blocked, and 6443 and 50000 are open. Plex's `healthCheckNodePort`
  30577 is closed.
- **Unaffected:**
    - etcd (3 members), kubectl through the VIP, `kubectl logs` and `top`.
    - Every node-IP Prometheus scrape.
    - DNS from pods.
    - The LoadBalancer IPs, including Minecraft over UDP, the tor ports and
      syslog delivery to Loki.
    - Spegel and tuppr.
- **VIP traffic:** connections sourced from the VIP only go to the holder's own
  API server over loopback. No peer rule needs `192.168.5.254`.
- **Soak noise, unrelated to the firewall:**
    - Loki rollouts from #554 and its follow-up fix (ruler notification
      errors, and Hubble drops to old Loki pod IPs).
    - The new Sigma break-glass and secrets-enumeration alerts, which fired on
      the operator's own `kubectl exec`, port-forward and secret reads.
    - The unifi-external-dns crash-loop on UniFi API timeouts, which predates
      the firewall and was addressed in #614.
- **Closed out:** `topf apply --dry-run` shows no diff on any node, and
  `talos/rendered/` was deleted.

## Rollback and break-glass

- **During `try`:** wait up to 10 minutes. The revert is a node-local timer
  and needs no connectivity.
- **After the permanent apply, locked out of one node's apid:** go through
  another node's apid. Nodes are allowed to each other on 50000, so
  `talosctl -e 192.168.5.50 -n 192.168.5.51 apply-config -f <fixed>.yaml --mode no-reboot`
  works. To remove the firewall entirely, delete or rename both `80-firewall.yaml`
  files, run `just talos render`, and apply that config the same way.
- **Admin host off the LAN** (another VLAN, VPN): connect any machine that has
  the talosconfig to the `192.168.5.0/24` LAN. apid and 6443 accept the whole
  subnet, so no particular IP is required.
- **Kube API works but no apid path works:** the in-cluster Talos API
  (`kubernetesTalosAPIAccess`, `os:admin`, `system-upgrade` namespace) is
  allowed from the pod CIDR. Run a `talosctl` pod there with a
  `talos.dev/v1alpha1 ServiceAccount`. The namespace is default-denied by the
  tuppr CNP, so the pod has to match tuppr's egress policy (or needs a
  temporary CNP) to reach `default/talos:50000`.
- **Physical:** the MS-A2 nodes have no BMC. An HDMI monitor shows the Talos
  console dashboard, and the power button does a hard power cycle. A reboot
  does **not** remove the firewall, because the config lives in the encrypted
  STATE partition. The last resort is reinstalling that one node from the
  secure-boot ISO and re-applying its config with `just talos apply-node`.
  etcd keeps quorum with the other two, which is why the rollout never touches
  more than one node at a time.
- **Reboots:** if a reboot is needed for any reason, always use
  `talosctl reboot --mode powercycle` (per `AGENTS.md`; kexec reboots hang on
  this hardware).

## Monitoring

No new alerts are needed. Existing rules already fire if the firewall breaks a
scrape or health path: `TargetDown`, `KubeletDown`, `etcdMembersDown` /
`etcdInsufficientMembers`, `KubeControllerManagerDown`, `KubeSchedulerDown`,
`KubeAPIDown` and `CiliumAgentDown`.

A Gatus probe of apid would only test "port open from the pod CIDR", which is
allowed by design, so it adds nothing. An optional follow-up is a
**negative canary**: a Gatus TCP check with `[CONNECTED] == false` against
`<node>:111` from a pod (the pod CIDR isn't allowed on 111). It would catch the
firewall being silently dropped from the config. It needs a matching Gatus CNP
egress rule, so it's left out of this change.

## Follow-ups and caveats

- Node `/32`s are hardcoded. Update both files when adding a node. Admin hosts
  need no change as long as they are on `192.168.5.0/24`.
- Switching Cilium to tunnel mode would need UDP 8472 from the nodes. Enabling
  WireGuard (finding S8) would need UDP 51871 from the nodes.
- The ICMP allowance is a global 5 pkt/s ([#11546][t11546]). A LAN ping flood
  could starve cilium-health ICMP probes and make health flap. This only
  affects monitoring; the datapath isn't touched.
- IPv6 is disabled cluster-wide. With block mode, all IPv6 except ICMPv6 is
  dropped.
- NodePort and hostPort exposure: closed by #562 and #616 (see [Residual exposure](#residual-exposure-the-host-firewall-cannot-close)).

[talos-fw]: https://docs.siderolabs.com/talos/v1.14/networking/ingress-firewall
[talos-src]: https://github.com/siderolabs/talos/blob/v1.14.1/internal/app/machined/pkg/controllers/network/nftables_chain_config.go
[t12955]: https://github.com/siderolabs/talos/issues/12955
[t11546]: https://github.com/siderolabs/talos/issues/11546
[t14070]: https://github.com/siderolabs/talos/issues/14070
[cilium-fw]: https://docs.cilium.io/en/stable/operations/system_requirements/#firewall-rules
[cilium-kpr]: https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/
