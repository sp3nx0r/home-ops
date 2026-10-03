# Cilium CNP reference

## Hidden dependencies (each one caused a regression here)

| Workload                                                                            | Easily missed need                                                                                                                                                       |
| ----------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| cloudflared (`network/cloudflare-tunnel`)                                           | egress world **7844/UDP + 7844/TCP** (QUIC/HTTP2 tunnel); 443 is only API/updates                                                                                        |
| envoy-gateway controller (`network/envoy-gateway`)                                  | egress to envoy-internal proxy `:10443`. It fetches each OIDC SecurityPolicy's `https://id.${SECRET_DOMAIN}/.well-known/openid-configuration` itself                     |
| *arr apps, qui, sillytavern, openwebui                                              | egress to envoy-internal `:10443` (+`:10080`). They call sibling apps by internal hostname                                                                               |
| Anything dialing another namespace's Service                                        | explicit `toEndpoints` for that namespace (brrpolice/seasonpackerr → `download/qbittorrent-gluetun`)                                                                     |
| Flux source/kustomize/helm controllers                                              | egress to notification-controller pod `:9090` (Service :80 → pod `http` 9090)                                                                                            |
| Operators, garage, prometheus-adapter, `bitnami/kubectl` Jobs (Volsync cache-scrub) | `toEntities: [kube-apiserver]` :6443                                                                                                                                     |
| prometheus                                                                          | off-cluster scrape targets (`192.168.5.70/32` exporters), config-reloader `:8080`, cainjector `:9402`                                                                    |
| thanos-sidecar (in the prometheus pod)                                              | egress to Garage S3 `:3900`, so Garage ingress must allow prometheus                                                                                                     |
| plex                                                                                | world egress with no port restriction (relay/remote clients)                                                                                                             |
| gatus                                                                               | FQDN probes → `toFQDNs` + `ndots: 1`; raw-IP probes (UniFi `.1`, NAS `.40`) → `/32`. Echo/flux-webhook deliberately hairpin through Cloudflare; don't make them internal |
| Admission webhooks                                                                  | `fromEntities: [kube-apiserver, host, remote-node]` on the webhook port                                                                                                  |

Known-intentional broad rules: envoy-gateway world egress (reaches `192.168.5.70`), qbittorrent-gluetun all-port VPN egress, tor-relay world ingress, Flux sources `world:443`.

Cluster facts: pods `10.42.0.0/16`, services `10.43.0.0/16`, LAN `192.168.5.0/24` (TrueNAS `.40`, nodes `.50-.52`, VIP `.254`, ms-s1 `.70`). Re-check LB IPs with `rg -n 'lbipam.cilium.io/ips' kubernetes/apps`.

## Fan-out audit subagent prompt

```
You are auditing CiliumNetworkPolicies in /opt/home-ops (Talos + Flux, Cilium CNI). Each namespaced CNP is an
ALLOWLIST on top of a cluster-wide default-deny floor. READ-ONLY: do not edit.
CLUSTER FACTS: <pod/svc CIDRs, LAN IP map, intentional exceptions from reference.md>
CILIUM SEMANTICS: `world` = all non-cluster IPs INCLUDING the LAN; allow rules are additive (an `except:` narrows
only its own rule); ClusterIP is DNAT'd to the backend identity before egress policy, so in-cluster = toEndpoints,
never CIDR; the floor already allows DNS egress + host/remote-node/kube-apiserver/health ingress (all ports).
FLAG: (1) egress broader than needed (plain world, `cluster`, no toPorts); (2) world ingress on non-exposed apps;
(3) private CIDRs not justified/scoped; (4) kube-apiserver/host/remote-node not needed; (5) missing egress for a
host the helmrelease is configured to call, or port mismatch vs container port; (6) comment-vs-rule mismatch;
(7) no-op rules, policies selecting nothing, pods selected by no policy.
FILES: <list>. Read each CNP + sibling helmrelease.yaml.
OUTPUT: `<app>` — [OK|MINOR|FLAG] — one-line workload; 1-3 bullets for MINOR/FLAG (rule, why, fix).
End with "Top risks in <bucket>" (2-4 items).
```

## LB / NodePort / hostPort exposure (eBPF paths)

Cilium serves LoadBalancer IPs, NodePorts and non-hostNetwork hostPorts in eBPF before netfilter, so **the Talos host firewall doesn't filter them** ([siderolabs/talos#12955](https://github.com/siderolabs/talos/issues/12955)). The pod's CNP filters them after translation, using the real client identity. That works because KPR runs in DSR mode and preserves the client IP; if the LB mode changes to SNAT, LAN clients would appear as `remote-node`.

Inventory:

```sh
kubectl get svc -A -o json | jq -r '.items[]|select(.spec.type!="ClusterIP")|[.metadata.namespace,.metadata.name,.spec.type,(.spec.allocateLoadBalancerNodePorts|tostring),.spec.externalTrafficPolicy,([.spec.ports[]|"\(.port)/\(.protocol)=np\(.nodePort)"]|join(","))]|@tsv'
kubectl get pods -A -o json | jq -r '.items[]|. as $p|.spec.containers[]|.ports[]?|select(.hostPort)|"\($p.metadata.namespace)/\($p.metadata.name) hostNetwork=\($p.spec.hostNetwork//false) hostPort=\(.hostPort)"' | sort -u
```

Closing NodePorts:

- app-template: `service.<name>.allocateLoadBalancerNodePorts: false`. EnvoyProxy: `spec.provider.kubernetes.envoyService.allocateLoadBalancerNodePorts`. Charts without the value: a HelmRelease `postRenderers` patch targeting the LB Service with an **anchored** name.
- Flipping the flag doesn't free existing nodePorts, and SSA won't remove them (nothing owns `nodePort`). Removing nodePort while the flag is still `true` re-allocates it. Order: flag first (via Git), then a one-off `kubectl patch --type=json` removing `/spec/ports/<i>/nodePort`, dry-run first. Confirm UniFi forwards target LB IPs.
- Don't use `service.cilium.io/type: LoadBalancer`; it drops the ClusterIP frontend.
- `healthCheckNodePort` (eTP=Local, e.g. Plex) is a real cilium-agent socket, so the Talos firewall handles it.
- Spegel can't become ClusterIP: the containerd mirror dials `nodeIP:29999`/`:30021`. Protect it with an ingress CNP instead.
