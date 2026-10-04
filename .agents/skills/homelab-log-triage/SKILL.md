---
name: homelab-log-triage
description: Triages incidents across every log source in the home-ops Loki — Kubernetes pod logs, the apiserver audit stream, Hubble policy drops, and syslog from the TrueNAS NAS (themberchaud) and UniFi gateway. Covers the stream map and label quirks, a scope → volume → patterns → timeline → correlate workflow with the o11y.sh helpers (lq, lqt, lpat), known noise, and a NAS failure playbook (ZFS/zed, iSCSI, replication, NFS, UPS, democratic-csi). Use when something is broken or slow and the cause may be in logs, when asked "what happened on the NAS", or before diving into a source-specific skill.
---

# Homelab log triage

## Mission

Turn "something is wrong" into a timestamped, cross-source timeline with the noise removed, then hand off to the source-specific skill. Read-only.

## Prerequisites

- `source scripts/o11y.sh` from inside the repo (apiserver proxy, no port-forward):
    - `lq '<metric logql>'`: counts. `lqt '<logql>' [mins] [limit]`: newest-first lines as `UTC time  label values  message`.
    - `lpat '<selector>' [mins]`: Loki's pattern templates with counts. **Pattern data only covers ~3h.**
    - `lqr` returns the **oldest** `limit` lines of the window; use `lqt` for "latest". For bulk pulls, `o11y_cli_env` then `logcli query --batch` (see `o11y-history-forensics`).
- Retention 30d (`retention_period: 720h`), `query_timeout` 300s. The audit stream starts 2026-09-25.
- Helpers are shell functions: `timeout lq …` fails; raise the Shell call's `block_until_ms` for `[7d]` queries.

## Stream map

| `source`     | What                                                                 | Useful labels                                           | Line format                                   |
| ------------ | -------------------------------------------------------------------- | ------------------------------------------------------- | --------------------------------------------- |
| `kubernetes` | Pod logs (Vector agent, all nodes)                                   | `namespace`, `pod`, `container`, `node`, `service_name` | JSON; app JSON merged in, text in `.message`  |
| `kube-audit` | apiserver audit (metadata level)                                     | `verb` only                                             | Audit event JSON → `kube-audit-investigation` |
| `hubble`     | Cilium policy drops                                                  | `src_namespace`, `dst_namespace`, `direction`, `node`   | Flow summary → `hubble-drop-triage`           |
| `syslog`     | TrueNAS `host="themberchaud"` (192.168.5.40); UniFi `host="Schloss"` | `host`, `app`, `facility`, `severity`                   | JSON with `.message`                          |

Discover the rest live; don't guess label values:

```sh
L=/api/v1/namespaces/o11y/services/loki:3100/proxy/loki/api/v1
kubectl get --raw "$L/label/app/values?since=24h" | jq -c .data
lq 'sum by (source, service_name) (count_over_time({source=~".+"}[1h]))' | head -30
```

## Workflow

1. **Scope**: what broke, since when (in UTC), which components. Get the symptom first from metrics or alerts (`am`, `q`), so log-hunting has a time window.
2. **Volume over time** for each candidate stream: a step change dates the incident better than any single line.
    ```sh
    lq 'sum by (app) (count_over_time({source="syslog", host="themberchaud", severity=~"err|warning"}[1h]))'   # one window
    o11y_cli_env   # a series over time needs logcli
    logcli query --quiet --since=24h --step=15m -o raw 'sum by (app) (count_over_time({source="syslog", host="themberchaud"}[15m]))' \
      | jq -r '.[] | (.metric|tostring) + "  " + ([.values[] | "\(.[0] | strftime("%H:%M"))=\(.[1])"] | join(" "))'
    ```
3. **Collapse to patterns** before reading lines.
    - Within ~3h: `lpat '{source="syslog", host="themberchaud", app="kernel"}'`.
    - Older: pull lines and cluster locally:
        ```sh
        lqr '<selector>' 1440 5000 | jq -r '.message // .' \
          | sed -E 's/[0-9]+(\.[0-9]+){3}/<ip>/g; s/[0-9a-f]{12,}/<h>/g; s/[0-9]+/<n>/g' | sort | uniq -c | sort -rn | head
        ```
4. **Drop known noise** (below) with `!=` line filters, then read the newest real lines: `lqt '<selector> != "<noise>"' 120 50`.
5. **Correlate across sources** in one window. NAS kernel/iSCSI vs the democratic-csi pods vs app errors:
    ```sh
    for s in '{source="syslog", host="themberchaud"} |~ "(?i)error|fail|timeout|abort" != "Response timeout 90"' \
             '{source="kubernetes", namespace="kube-system", pod=~"democratic-csi.*"} |~ "(?i)error|fail" != "GRPC error: <nil>"' \
             '{source="kubernetes", namespace="<ns>"} |~ "(?i)i/o error|read-only|timeout"'; do
      lqt "$s" 120 20; done | sort -r | head -60
    ```
6. **Hand off** with the timeline: storage latency → `iscsi-storage-latency-triage`; API or RBAC activity → `kube-audit-investigation`; connectivity → `hubble-drop-triage`; rollout → `flux-rollout-watch`; resource history → `o11y-history-forensics`.

## NAS playbook (themberchaud)

| Symptom                          | Selector (`{source="syslog", host="themberchaud", …}`) | Look for                                                                                                                                                               |
| -------------------------------- | ------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pool, disk or checksum trouble   | `app="zed"`                                            | any `class=` outside the 30d baseline (`scrub_start`/`scrub_finish`, `config_sync`, `pool_import`, `vdev_autoexpand`), e.g. `checksum`, `io`, `statechange`, `deadman` |
| Disk or HBA errors               | `app="kernel"` `!= "iscsi-scst"` `!= "scst:"`          | `I/O error`, `blk_update_request`, `ata`/`sd` resets, `mpt3sas`                                                                                                        |
| iSCSI PVCs slow or disconnecting | `app="kernel"` `\|= "iscsi-scst"`                      | session create/close churn, `Aborting`, `TM fn` with non-zero status. Pair with `iscsi-storage-latency-triage`                                                         |
| Replication or snapshots         | `app="ZETTAREPL"`, `app="MIDDLEWARE"` `\|= "Snapshot"` | failures, gaps against the schedule                                                                                                                                    |
| NFS mounts (media, app configs)  | `app="rpc.mountd"`, `app="kernel"` `\|= "nfsd"`        | refused or stale mounts                                                                                                                                                |
| Power events                     | `app=~"usbhid-ups\|nut-.*\|upsd\|upssched"`            | on-battery, low-battery, comms lost                                                                                                                                    |
| Middleware or API errors         | `app="MIDDLEWARE"`, `severity="err"`                   | `(ERROR)` lines                                                                                                                                                        |

On the Kubernetes side, democratic-csi logs live in `kube-system` (`democratic-csi-controller-*`, `democratic-csi-node-*`; containers `csi-driver`, `csi-proxy`, `external-*`). The node pod on the affected node is the one that matters for a stuck mount.

## Known noise (verified 2026-10)

- `app="sshd"`/`systemd-logind`: about 31k/week `truenas_admin` public-key sessions. This is democratic-csi's SSH driver, not an attack. A login by any **other** user or key is worth a look.
- `app="ed"`: `pam_unix(middleware-api-key:session)` for user `prometheus`, the metrics exporter's API key.
- `app="MIDDLEWARE"` WARNING `Private method 'smb.status' called…` (~470/day); `systemd` `Cannot find unit for notify message`.
- `app="kernel"` `iscsi-scst` session/negotiation blocks: ~130 sessions/day is the baseline; worry about a sudden rise.
- `severity="err"` from `syslog-ng` about TrueNAS's own audit SQLite (`database is locked`): internal to TrueNAS.
- democratic-csi `external-provisioner` logs `GRPC error: <nil>` on every successful call; iSCSI negotiation lines contain `Response timeout 90`. Both match naive `error|timeout` filters.
- `kubernetes`: highest volume is `csi-driver`, `prometheus-adapter`, Flux `manager`, `garage`, `csi-proxy`. Filter by `detected_level` first.

## Gotchas & Edge Cases

- **The Kubernetes `namespace` (and possibly `pod`) label lies for JSON-logging apps.** Vector's `kube_parse` sets them from pod metadata, then `merge!`s the app's JSON over them. Flux controllers and Kubescape pods show up under up to 15 namespaces. Select them by `pod=~"<name>.*"`.
- **UniFi timestamps are ~5h behind**: the gateway sends local time without a timezone. Its hostname `Schloss von Koch` gets split, so `host="Schloss"` and `von Koch` leaks into the message. NAS timestamps are correct.
- `lqt` labels are values only (`app/facility/host/severity`); use `lqr | jq` when you need the keys.
- Syslog `severity` is the sender's; `detected_level` is Loki's guess from the text. TrueNAS logs INFO-level middleware lines as `warning`.
- `| json` skips arrays; extract them explicitly (`json ip="sourceIPs[0]"`).
- One condition per `lq` filter when results come back empty; empty can't tell "no hits" from "bad filter". Prove a filter by dropping it first.
- Your own queries show up in the audit stream as `admin` from the workstation IP.

## Output Template

```text
Incident window: <start>–<end> UTC (detected via <alert/metric>)
Timeline:
  13:02:10Z  NAS kernel     iscsi-scst: Aborting cmd … (target …)
  13:02:11Z  csi-node/aurinax  rpc error: … timeout
  13:02:40Z  media/sonarr   database is locked
Noise excluded: <filters>
Most likely cause: <one sentence>, confidence <low|med|high>
Handed off to: <skill> — next check: <command>
```
