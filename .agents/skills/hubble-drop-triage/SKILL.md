---
name: hubble-drop-triage
description: Turns Cilium/Hubble DROPPED flows in home-ops into a short classified list of real policy gaps, using metrics for cadence, Loki for history and live Hubble capture only when needed. Covers drop reasons, IP/FQDN attribution, the HubblePolicyDenied alert and its exclusions, and long soaks. Use when HubblePolicyDenied fires, the user asks "are there drops" or "what is X being denied to", asks to watch for drops for N hours, or after a CNP merge.
---

# Hubble drop triage

## Mission

Go from "something is being dropped" to named src → dst:port pairs, each classified as fix / expected / transient / not-policy, with evidence. Change nothing live.

## Prerequisites

- Query helpers (apiserver proxy, no port-forward): `source scripts/o11y.sh` from inside the repo gives `q`, `qr`, `lq`, `lqr`, `am`.
- `docs/completed/cluster-default-deny-floor.md` **"Expected drops"** section. Read it before reporting anything as new.
- Alert: `kubernetes/apps/kube-system/cilium/app/prometheusrule.yaml` (`HubblePolicyDenied`: 10m `increase`, `for: 15m`, ICMP excluded, plex UDP → host/kube-apiserver and `kubescape/kubevuln` → world TCP excluded).
- Dashboard: Grafana **Network → Hubble Policy Drops**. Writing the fix: `cilium-cnp-authoring`.

## Pick the layer

| Question                                         | Source                                                              | Why                                                                                                                                                                          |
| ------------------------------------------------ | ------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| How many, which pairs, what reason, what cadence | `hubble_drop_total` (`source`, `destination`, `reason`, `protocol`) | Long history; no ports or FQDNs                                                                                                                                              |
| Which port / IP / name, over hours or days       | Loki `{source="hubble"}`                                            | Exported **policy drops only** (`policy-drops*.log`); JSON with `src`, `dst`, `dst_ip`, `dst_port`, `protocol`, `direction`, `drop_reason`, `src_names`, `dst_names`, `node` |
| Live, while exercising a path                    | Hubble relay or a loop over every agent                             | The per-node ring buffer held only ~90 s on busy nodes; useless for history                                                                                                  |

## Workflow

1. **Alert state and the big picture**:
    ```sh
    source scripts/o11y.sh
    am | rg HubblePolicyDenied
    q 'sum by (reason) (increase(hubble_drop_total[1h])) > 0'
    q 'sum by (source,destination,protocol) (increase(hubble_drop_total{reason="POLICY_DENIED"}[1h])) > 0'
    ```
    **Classify by reason first.** Only `POLICY_DENIED` (floor or missing allow) is a policy gap. `POLICY_DENY` is an explicit `egressDeny`/`ingressDeny` (intentional). `VLAN_FILTERED`, `UNSUPPORTED_L3_PROTOCOL`, `CT_UNKNOWN_L4_PROTOCOL`, `FIB_LOOKUP_FAILED` are node/L2 noise. "Service backend not found" means the Service lacks that port/protocol (e.g. `media/qbittorrent-bittorrent` is TCP-only, so uTP/DHT UDP drops): fix the Service, not the policy.
2. **Cadence** per pair: `qr 'sum(increase(hubble_drop_total{reason="POLICY_DENIED",source="<ns>/<pod-prefix>"}[1m]))' 120 60`. A startup burst won't page. A 5-minute periodic probe keeps the 10m window non-zero and pages.
3. **Ports and names from Loki**:
    ```sh
    lqr '{source="hubble", src_namespace="<ns>"}' 180 5000 > /tmp/drops.jsonl; wc -l < /tmp/drops.jsonl   # == limit → narrow it
    jq -r '[.src, .dst, (.dst_names // [] | join(",")), .dst_ip, .protocol, (.dst_port // "-"), .direction] | @tsv' /tmp/drops.jsonl \
      | sort | uniq -c | sort -rn | head -40
    ```
    Filter by labels `src_namespace`, `dst_namespace`, `direction`, `node`. For a quick count: `lq 'sum by (src_namespace,dst_namespace) (count_over_time({source="hubble"}[1h]))'`.
4. **Live capture (only when you need flows Loki doesn't have)**. Hubble relay is `kube-system/hubble-relay:80`.
    - With the CLI: `cilium hubble port-forward` in its own call (capture the PID), then `hubble observe --verdict DROPPED --namespace <ns> --follow`.
    - Without the CLI, loop **every** agent; `exec ds/cilium` picks one node and an empty result was misread as "no drops":
        ```sh
        for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
          timeout 150 kubectl -n kube-system exec $p -c cilium-agent -- hubble observe --namespace <ns> --verdict DROPPED --follow -o json > /tmp/live-${p#pod/}.json 2>/dev/null &
        done; wait
        ```
    - Filter on `--namespace` and group with `jq` on `.flow.source.pod_name`. `--label`/`--from-label` filters returned partial results.
5. **Attribute unknown IPs**: `kubectl get pods,svc -A -o wide | rg '<ip> '` and `kubectl get ciliumendpoints -A -o wide | rg '<ip>'`. No match usually means an old pod IP (stale/transient). For world IPs, check the same pod's DNS flows (`hubble observe --protocol dns`) or its logs (`rg -o 'https?://[a-zA-Z0-9.-]+|dial tcp [0-9.:]+'`).
6. **Root-cause before proposing anything**:
    - A pod that lost **all** traffic at once: check `kubectl get cnp -A` VALID. A Cilium restart exposed a latent `Valid=False` CNP and syslog was lost for 8 minutes.
    - `dst` is bare `world` for an FQDN you allowed, or `dst_names` has `*.svc.cluster.local`: the pod lacks `ndots: 1`.
    - New since a deploy? `git log --oneline -10 -- kubernetes/apps/<ns>`. Cross-check app logs for matching errors.
    - Before calling anything "stale" or "pre-existing", confirm it against the repo and live state. The owner corrected this exact mistake.
7. **Choose the fix**:
    | Situation                                                                                                                | Fix                                                                                                                      |
    | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------ |
    | Legitimate need                                                                                                          | allow rule (`toFQDNs` + `ndots: 1`, or `toEndpoints`) via `cilium-cnp-authoring`                                         |
    | Unwanted, fixed IP/CIDR (kubescape node-agent probing `169.254.169.254` every 5 min)                                     | `egressDeny` + `toCIDR` in the app CNP; it then logs `POLICY_DENY`, which the alert ignores                              |
    | Unwanted, varying hosts                                                                                                  | `unless on (source, destination, protocol)` carve-out in `HubblePolicyDenied` + a line in the floor doc's Expected drops |
    | One-off burst, ICMP to a Service with no endpoints yet, self-generated test traffic                                      | none; note it                                                                                                            |
    | `egressDeny` can't use `toFQDNs`, and deny beats allow. A carve-out hides future legitimate needs for that pair; say so. |
8. **Validate an alert change** by evaluating old and new `expr` at a timestamp inside the bad window: `q "$new" <ts>` vs `q "$old" <ts>`. The noisy pair must vanish while others still match.
9. **After the fix merges**: the reason flips to `POLICY_DENY` (or the pair disappears) after the next expected burst, and `am` no longer lists the alert ~10 minutes later.

## Long soak ("watch for N hours")

Infrequent flows (nightly Volsync cache-scrub, hourly GeoLite refresh) only show up over hours. Prefer querying Loki once per tick (step 3 with a window matching the tick); it needs no background process and survives agent restarts. Use the `loop` skill for ticks.

If policy-allowed flows or non-policy drops matter (Loki only has policy drops), run a self-restarting live capture. It needs the relay port-forward from step 4 running first:

```sh
nohup bash -c 'while :; do hubble observe --verdict DROPPED --follow -o json >> /tmp/hubble-drops.jsonl; sleep 5; done' >/dev/null 2>&1 &
echo $! > /tmp/hubble-soak.pid
```

Keep a line cursor so each tick triages only new lines. Tell the user how to stop it: `kill $(cat /tmp/hubble-soak.pid)`, plus the port-forward PID.

## Gotchas & Edge Cases

- Metrics vs Hubble mismatch (421 drops in metrics vs 18 flows visible): the buffer had rotated. Trust the per-minute timeline.
- `HubblePolicyDenied` lags: it fires after sustained drops and clears ~10 min after they stop. Check when the last real drop happened before calling it a new issue.
- Transient `prometheus → reserved:world <pod-ip>` right after pod churn: stale scrape targets. Expected.
- Your own `wget` tests from app pods show up as denials. Exclude them.
- An unrelated namespace's alert can appear mid-watch. Report it separately.
- Docs can be wrong (kubescape drops contradicted `docs/completed/kubescape.md`). Propose a doc fix.
- Never `pkill -f port-forward` chained in the same command; it has killed the agent's shell. Kill by PID.

## Output Template

```
Window: <start–end UTC> · sources: metrics / Loki (<N> flows) / live (<s>)
Alert: HubblePolicyDenied <firing|pending|clear> for <pairs>
By reason: POLICY_DENIED <n> · POLICY_DENY <n> · L2/other <n>
Needs action:
| src | dst:port/proto (name) | cadence | cause/evidence | proposed fix |
Transient: <pair — why>
Expected (floor doc): <pairs>
Not policy: <e.g. Service missing UDP port>
```
