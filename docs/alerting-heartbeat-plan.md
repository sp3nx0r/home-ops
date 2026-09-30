# Alerting Heartbeat (Dead Man's Switch) and Outside-In Monitoring

Status: implemented in PR `feat/alertmanager-heartbeat` (draft). External
accounts and checks are created manually (steps below).

Addresses findings from `sre-and-security-evaluation.md`:

- **O1**: `Watchdog` was routed to `blackhole`, so there was no dead man's switch.
- **O2**: Discord was the only notification channel (planned here, not implemented).
- **O5**: there was no outside-in probing. Gatus runs in-cluster, so a
  Cloudflare/tunnel/uplink failure goes unnoticed.
- **O9**: Alertmanager ran as a single replica on emptyDir.

## What catches what

| Failure                                                 | Detected by                                                            | Notified via                               |
| ------------------------------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------ |
| Prometheus dead / rule evaluation stuck                 | Watchdog stops reaching Alertmanager → pings stop → healthchecks.io    | healthchecks.io integrations (off-cluster) |
| Both Alertmanager replicas dead / crash-looping         | pings stop → healthchecks.io                                           | healthchecks.io                            |
| Cluster egress, CNP, DNS or WAN uplink broken           | pings stop → healthchecks.io                                           | healthchecks.io                            |
| Whole cluster / power / all nodes down                  | pings stop → healthchecks.io                                           | healthchecks.io                            |
| Cloudflare edge, tunnel, `envoy-external` or public DNS | UptimeRobot HTTP checks from the internet                              | UptimeRobot (off-cluster)                  |
| One Alertmanager replica down / mesh split              | `AlertmanagerClusterDown`, `AlertmanagerMembersInconsistent` (default) | Discord (via the surviving replica)        |
| Discord webhook failing (Alertmanager can't send)       | `AlertmanagerFailedToSendAlerts{integration="discord"}`                | Discord only — **the O2 gap**              |

## Research

Free-tier limits as published on 2026-09-30.

| Service                                                                                                                                                                            | Heartbeat on free tier                                                                                                                                                                                                                                        | Outside-in HTTP on free tier                                                                                                        | Free alert channels                                                                                                                                                                                                                   | Ping URL secrecy                                                     | API / IaC                                                                                                                                   |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| [healthchecks.io](https://healthchecks.io/pricing/) (Hobbyist)                                                                                                                     | **20 checks**, 100 log entries/check, unlimited team members ([since 2026-02](https://blog.healthchecks.io/2026/02/unlimited-team-sizes-for-all/))                                                                                                            | No (passive only)                                                                                                                   | Email, webhook, **Discord**, Slack, **ntfy**, **Pushover**, Signal, Telegram, Matrix, Gotify, PagerDuty, Opsgenie, … ([integrations](https://healthchecks.io/)). SMS/WhatsApp/phone need paid credits (Business: 50 SMS, 20 calls)    | UUID URL (or project ping key + slug); can restrict to **POST only** | [Management API v3](https://healthchecks.io/docs/api/) with upsert (`unique`); community Terraform provider; open source (self-host option) |
| [UptimeRobot](https://uptimerobot.com/pricing/) (Free)                                                                                                                             | **Conflicting sources.** The pricing table ("Solo: all monitor types") and the [heartbeat launch post](https://uptimerobot.com/blog/new-feature-heartbeat-monitoring/) put it on paid plans; one help-centre article says Free includes it. Treat it as paid. | **50 monitors, 5-min interval**, HTTP/keyword/ping/port, SSL/domain expiry                                                          | Email, **Discord**, Google Chat, Pushbullet, Splunk ([integrations by plan](https://help.uptimerobot.com/en/articles/11361285-uptimerobot-integrations-basic-information-overview)). The Pushover page says Solo+. Webhooks are Team+ | Heartbeat URL (paid)                                                 | [REST API v3](https://uptimerobot.com/blog/introducing-the-uptimerobot-v3-api/) with bearer token; free plan limited to 10 req/min          |
| [Cronitor](https://cronitor.io/pricing) (Hacker)                                                                                                                                   | Yes, but **5 monitors total** (heartbeats + uptime + cron share the quota)                                                                                                                                                                                    | Yes (same 5-monitor quota), 5-min min frequency                                                                                     | Email, Slack (the table also lists Discord/Teams/webhooks as "chat alerts" on all plans); no SMS                                                                                                                                      | Unique ping URL                                                      | REST API                                                                                                                                    |
| [Better Stack](https://betterstack.com/pricing) (Free)                                                                                                                             | Yes: **10 monitors & heartbeats combined**, 1 status page                                                                                                                                                                                                     | Yes (same quota)                                                                                                                    | **Email and Slack only** on free; phone/SMS/push need a Responder licence ($29–34/mo)                                                                                                                                                 | Unique heartbeat URL                                                 | REST API + official Terraform provider                                                                                                      |
| [Dead Man's Snitch](https://deadmanssnitch.com/plans)                                                                                                                              | **1 snitch** free ($5/mo for 3), "basic intervals"                                                                                                                                                                                                            | No                                                                                                                                  | Email; integrations on paid plans                                                                                                                                                                                                     | Unique URL                                                           | API                                                                                                                                         |
| Grafana Cloud Free: [IRM](https://grafana.com/docs/grafana-cloud/alerting-and-irm/irm/integrations/configure-integrations/) + [Synthetic Monitoring](https://grafana.com/pricing/) | Yes: IRM Alertmanager/Webhook integration with heartbeat settings; 3 active IRM users                                                                                                                                                                         | Yes: 100k API test executions/month (`probes × checks × 43,200 / frequency_min`; for example 4 checks × 2 probes every 5 min = 69k) | IRM mobile push, email, Slack, …                                                                                                                                                                                                      | Integration URL token                                                | Official Grafana Terraform provider. Heaviest option (another stack to run). Grafana OnCall OSS is archived                                 |
| Self-hosted Gatus off-site (the [onedr0p](https://github.com/onedr0p/home-ops) `buddy` and [bjw-s](https://github.com/bjw-s-labs/home-ops) `icarus` pattern)                       | Yes: Gatus external endpoint + bearer token                                                                                                                                                                                                                   | Yes, from wherever the box lives                                                                                                    | Anything Gatus supports                                                                                                                                                                                                               | Bearer token + URL                                                   | GitOps. **Needs an always-on off-site host** (VPS), which then needs monitoring itself                                                      |

### How other home-ops repos do it

- **onedr0p/home-ops**: `AlertmanagerConfig` route `alertname = Watchdog` →
  `buddy-heartbeat` webhook (`urlSecret` + `bearerTokenSecret` from
  `alertmanager-secret`), `groupWait: 0s`, `groupInterval: 2m`,
  `repeatInterval: 2m30s`. The receiver is a Gatus instance on an off-site
  box. That box also runs ICMP and status-page checks against the home
  network and alerts via Pushover.
- **bjw-s-labs/home-ops**: the same pattern (`icarus-heartbeat`, a Gatus on a
  VPS).
- Both keep the heartbeat URL in `alertmanager-secret`, not in a cluster-wide
  secret.

Note on their timings: with a 2m `group_interval`, a 2m30s `repeat_interval`
makes the ping go out every **4m** (see the timing math below).

## Decision

**healthchecks.io (heartbeat) + UptimeRobot Free (outside-in HTTP).**

- **healthchecks.io** is purpose-built for this. The free tier is generous:
  20 checks, which leaves room to heartbeat the B2 sync, etcd snapshots (B1),
  and restore drills (B2). Pings can be restricted to POST so a URL preview or
  crawler can't fake one. The free channels include Discord, ntfy, Pushover
  and email. The API upserts, so setup is idempotent. It is also open source,
  so the exit path is to self-host it on an off-site box.
- **UptimeRobot** fills the gap healthchecks.io can't: probing the public URLs
  from the internet. 50 free monitors at 5 minutes, with Discord + email
  alerts on the free tier. Its free heartbeat is doubtful, so it isn't used
  for that.
- **Runner-up, single vendor:** Grafana Cloud (IRM heartbeat + Synthetic
  Monitoring) if one account and Terraform matter more than simplicity.
  Better Stack's free tier alerts only via email/Slack.
- **Later:** an off-site Gatus (onedr0p/bjw-s pattern) if a VPS ever exists.
  It would replace both services and be GitOps-managed.

## Implementation (this PR)

### Alertmanager receiver and route

```yaml
receivers:
    - name: heartbeat
      webhook_configs:
          - url_file: /etc/alertmanager/secrets/alertmanager-secret/HEARTBEAT_PING_URL
            send_resolved: false
route:
    routes:
        - receiver: heartbeat
          matchers: [alertname = Watchdog]
          group_wait: 0s
          group_interval: 1m
          repeat_interval: 50s
```

`send_resolved: false` is essential. When Prometheus dies, Watchdog stops
being re-sent and resolves in Alertmanager. A resolved POST would count as a
successful ping at exactly the moment it should stop.

### Timing math (Alertmanager v0.34.1 source)

- The aggregation group flushes at `group_wait` (0s → immediately), then on
  every `group_interval` tick. The dispatcher passes the **tick time** as
  `now` (`dispatch.go`: `notify.WithNow(ctx, now)`).
- `DedupStage.needsUpdate` sends a repeat only if
  `entry.Timestamp < now − repeat_interval` (`notify/dedup_stage.go`).
- The notification-log entry is stamped with the wall clock **after** the
  POST returns (`nflog.Log`: `now := l.now()`), so it is `tick + δ`.
- At the next tick, `tick + δ < (tick + gi) − repeat` holds only when
  `repeat < gi − δ`. So:
    - `repeat_interval == group_interval` → skipped every other tick → pings
      every **2 × gi**.
    - `repeat_interval = 50s`, `group_interval = 1m` → a ping **every ~60s**,
      with 10s of headroom for send latency.
- **HA (2 replicas):** the second replica waits `peer_timeout` (15s) × its
  position, then dedups against the gossiped log. The primary's last send is
  within 50s of that, so it skips. If gossip is broken, both replicas ping,
  which is harmless for a heartbeat.
- **Watchdog lifetime after Prometheus death:** evaluation interval is 30s and
  `resend_delay` is 1m, so alerts carry `EndsAt = now + 4m`. Alertmanager keeps
  Watchdog firing (and pinging) for up to about 4m after Prometheus's last
  send.

With the healthchecks.io check at **period 5m, grace 5m**:

| Failure                                 | Worst-case time to notification    |
| --------------------------------------- | ---------------------------------- |
| Alertmanager / network / uplink / power | last ping + 5m + 5m ≈ **10 min**   |
| Prometheus only                         | ≈ 4m + 10m ≈ **14 min**            |
| Tolerated before a false alarm          | ~9 missed pings (e.g. AM restarts) |

A 10m grace (period 5m + grace 10m) would push these to 15 and 19 minutes.
The 5m grace is enough because an Alertmanager pod restart re-pings within
about a minute (Prometheus re-sends Watchdog every minute and `group_wait` is
0s).

### Secret handling: `url_file` from `alertmanager-secret`

The ping URL is a key in the existing namespace-scoped SOPS secret
`kubernetes/apps/o11y/kube-prometheus-stack/app/secret.sops.yaml`
(`alertmanager-secret`, which already holds `DISCORD_WEBHOOK_URL`). It is
mounted into the pods via `alertmanagerSpec.secrets` and read with
`url_file`. It is **not** in `cluster-secrets` and not substituted by Flux,
because:

- Flux `postBuild` substitution would render the URL in plaintext into the
  HelmRelease spec (readable by anyone who can `get helmreleases`), the Helm
  release secret and the generated config. With `url_file` it lives only in
  the Secret and the pod's tmpfs mount.
- `cluster-secrets` is copied into every namespace. This value is needed only
  by Alertmanager.
- Alertmanager re-reads `url_file` on every notification (whitespace-trimmed,
  `notify/webhook/webhook.go`), so rotating the URL needs no config reload or
  Helm upgrade.
- It matches onedr0p/bjw-s, who keep heartbeat URLs in `alertmanager-secret`.

The key currently holds the placeholder `https://hc-ping.com/REPLACE_WITH_UUID`.
**Replace it before merging.** Otherwise every ping gets a 404, and
`AlertmanagerFailedToSendAlerts` / `AlertmanagerClusterFailedToSendAlerts`
(`integration="webhook"`) fire to Discord.

### Network policy

The `alertmanager` CNP gains an explicit `toFQDNs: matchName: hc-ping.com`
egress on 443. The existing Discord rule (`0.0.0.0/0` minus private ranges,
:443) already allows it. The named rule pins the dependency so it survives
narrowing that rule to `toFQDNs: discord.com` (a recommended follow-up). DNS
is already L7-inspected by the policy (`matchPattern: "*"`), which `toFQDNs`
requires.

### Alertmanager HA (O9, separate commit)

- `alertmanagerSpec.replicas: 2`. The chart default `podAntiAffinity: soft`
  spreads the replicas across nodes. The operator enables the memberlist mesh
  (`--cluster.peer=…alertmanager-operated:9094`) once replicas > 1.
- `podDisruptionBudget.enabled: true` (`minAvailable: 1`,
  `unhealthyPodEvictionPolicy: AlwaysAllow`). Drains take one pod at a time and
  are never blocked by a broken pod. This is the cluster's first PDB and fits
  R5's rule of "only for multi-replica services".
- CNP: ingress and egress on 9094 TCP+UDP between `app.kubernetes.io/name:
alertmanager` pods.
- Benefit beyond availability: storage is emptyDir, so today **silences are
  lost on every Alertmanager restart**. With two replicas they are gossiped
  and survive a single pod restart.
- Prometheus already discovers every Alertmanager pod through the Service
  endpoints and sends to all of them, which is what HA requires.
- **Interaction with PR #554 (Loki ruler):** that PR sets
  `alertmanager_url: http://kube-prometheus-stack-alertmanager.o11y.svc…:9093`,
  a load-balanced Service. With 2 replicas, each alert then reaches only one
  replica. Alerts themselves are _not_ gossiped, only silences and the
  notification log. When rebasing, switch the ruler to all pods:

    ```yaml
    ruler:
        alertmanager_url: dnssrvnoa+http://_http-web._tcp.alertmanager-operated.o11y.svc.cluster.local
        enable_alertmanager_discovery: true
    ```

## External setup (manual)

Do not reuse the Alertmanager Discord webhook for the external services.
Create a **separate Discord webhook** (ideally a separate channel with
notifications on), so healthchecks.io and UptimeRobot alerts stand out and
don't depend on the Alertmanager webhook still being valid.

### healthchecks.io

1. Sign up at <https://healthchecks.io/> (Hobbyist, no card). Rename the
   default project to `home-ops`.
2. **Integrations** (project → Integrations → Add):
    - Email: already present for the account owner.
    - Discord: "Add Integration" → Discord → authorise the new webhook/channel.
    - Optional (see O2): ntfy (server `https://ntfy.sh`, a long random topic,
      priority high) or Pushover.
    - Give each integration a unique name (the API can reference them by
      name).
3. **Create the check.** Use either the API or the UI.
    - **API (recommended, idempotent):** Project Settings → API Access →
      "Create API key" (read-write). Then, from the repo root on the
      `feat/alertmanager-heartbeat` branch:

        ```sh
        HC_API_KEY='<read-write key>' just monitoring healthchecks
        git add kubernetes/apps/o11y/kube-prometheus-stack/app/secret.sops.yaml
        git commit -m 'chore(alertmanager): set healthchecks.io ping URL'
        ```

        The recipe upserts the check by slug (`alertmanager-watchdog`) with
        timeout 300s, grace 300s, POST-only, all integrations attached. It then
        writes the ping URL into the SOPS secret with `sops set` without printing
        it. Re-running it is safe. Override the timings with
        `just monitoring healthchecks 300 600`. Revoke the API key afterwards, or
        keep a read-only one for dashboards.

    - **UI:** Add Check → Name `Alertmanager Watchdog`, slug
      `alertmanager-watchdog` → Schedule: _Simple_, Period **5 minutes**, Grace
      **5 minutes** → Advanced / "Allowed request methods": **Only POST** →
      Notification methods: enable all → copy the ping URL, then:

        ```sh
        sops set kubernetes/apps/o11y/kube-prometheus-stack/app/secret.sops.yaml \
          '["stringData"]["HEARTBEAT_PING_URL"]' '"https://hc-ping.com/<uuid>"'
        ```

4. Optional: Account Settings → Email Reports → "Send hourly reminders while
   any check is down", so a missed notification nags.

### UptimeRobot (outside-in HTTP)

These endpoints are exposed publicly via Cloudflare → `cloudflared` →
`envoy-external`. Expected responses were verified from outside on
2026-09-30:

| Monitor  | URL                                      | Expect | Notes                                           |
| -------- | ---------------------------------------- | ------ | ----------------------------------------------- |
| `status` | `https://status.${SECRET_DOMAIN}/`       | 200    | Gatus status page                               |
| `echo`   | `https://echo.${SECRET_DOMAIN}/`         | 200    | Cheapest end-to-end tunnel probe                |
| `plex`   | `https://plex.${SECRET_DOMAIN}/identity` | 200    | `/` returns 401; `/identity` is unauthenticated |
| `kromgo` | `https://kromgo.${SECRET_DOMAIN}/`       | 200    | Badge API                                       |

`flux-webhook.${SECRET_DOMAIN}/` returns **404** by design (only
`/hook/<token>` exists), and UptimeRobot counts 404 as down. Custom success
codes (`successHttpResponseCodes: ["404"]`) may need a paid plan. `echo` and
`status` already cover the same Cloudflare → tunnel → `envoy-external` path,
and GitHub shows failed webhook deliveries, so it is left out.

1. Sign up at <https://uptimerobot.com/> (Free).
2. Integrations → **Discord** → paste the separate Discord webhook. Email is
   the default alert contact.
3. **Create the monitors.** Use either the API or the UI.
    - **API (idempotent):** Integrations & API → API → create the **Main API
      key**. Then:

        ```sh
        UPTIMEROBOT_API_KEY='<main api key>' just monitoring uptimerobot
        ```

        This creates any of the four monitors that don't exist yet (matched by
        exact URL). They use HTTP GET, a 5-min interval and a 30s timeout, and
        attach every alert contact returned by `/v3/user/alert-contacts`. It stays
        under the free plan's 10 req/min. If Discord doesn't show up as an attached
        contact on a monitor, attach it in the UI (Monitor → Edit → Notifications).

    - **UI:** "New monitor" → HTTP(s) → URL from the table → interval 5 min →
      tick Email + Discord → Create. Repeat for each row.
4. If Cloudflare Bot Fight Mode or WAF rules challenge the probes (monitors
   show 403/503), add a WAF skip rule for UptimeRobot's published IP ranges.

## Test procedure (after merge, with real URLs in SOPS)

1. **Pipeline is healthy.**

    ```sh
    kubectl -n o11y get pods -l app.kubernetes.io/name=alertmanager -o wide   # 2/2, different nodes
    kubectl -n o11y exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
      amtool cluster show --alertmanager.url=http://localhost:9093             # 2 peers, ready
    kubectl -n o11y exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
      amtool config routes test --config.file=/etc/alertmanager/config_out/alertmanager.env.yaml \
      alertname=Watchdog                                                        # -> heartbeat
    hubble observe -n o11y --pod alertmanager-kube-prometheus-stack-0 --verdict DROPPED --last 50
    ```

    The healthchecks.io dashboard shows `up` and "last ping" < 1 min, and the
    ping body is the Watchdog webhook JSON. In Prometheus,
    `rate(alertmanager_notifications_failed_total{integration="webhook"}[5m])`
    is 0.

2. **Dead man's switch fires.** Stop Alertmanager. Suspend the HelmRelease
   first so Helm doesn't fight the change.

    ```sh
    flux -n o11y suspend helmrelease kube-prometheus-stack
    kubectl -n o11y patch alertmanager kube-prometheus-stack --type merge -p '{"spec":{"replicas":0}}'
    date   # start timer
    ```

    Expect healthchecks.io to show `late` at about 5 min and `down` at about
    10 min after the last ping, with email and Discord (plus ntfy/Pushover if
    configured) from healthchecks.io. Then restore:

    ```sh
    kubectl -n o11y patch alertmanager kube-prometheus-stack --type merge -p '{"spec":{"replicas":2}}'
    flux -n o11y resume helmrelease kube-prometheus-stack
    ```

    Expect an `up` notification within about a minute of the pods being Ready.

    Optional Prometheus-only variant: patch the `prometheus` CR to
    `replicas: 0` instead. Watchdog resolves after up to 4m, and the
    healthchecks.io alert follows about 10m later. This interrupts metrics
    collection.

3. **Outside-in fires.** Take `echo` down for about 15 minutes:

    ```sh
    flux -n network suspend helmrelease echo
    kubectl -n network scale deployment echo --replicas 0
    # wait for UptimeRobot "down" (<= 5-10 min), then:
    kubectl -n network scale deployment echo --replicas 1
    flux -n network resume helmrelease echo
    ```

    UptimeRobot's "Test notification" on each alert contact is a
    non-disruptive check of the delivery path.

4. **Normal alerts are unaffected.** `amtool alert add alertname=RoutingTest
severity=warning --annotation=summary=test` from the Alertmanager pod
   reaches Discord exactly once, which confirms HA dedup.

## O2: second notification path for critical alerts (plan only)

The heartbeat covers "Alertmanager/Prometheus is dead" through a path that
doesn't touch Discord. What's still single-channel is **critical alerts while
the pipeline is healthy but Discord is broken or muted**. Options:

| Option                          | Account                                             | Alertmanager support                                                                     | Notes                                                                                                                 |
| ------------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| **Pushover** (recommended)      | Yes ($5 one-time per platform after a 30-day trial) | Native `pushover_configs` (`user_key_file`, `token_file`)                                | Emergency priority (2) repeats until acknowledged and bypasses DND. What onedr0p and bjw-s use                        |
| **ntfy.sh** (no account needed) | No                                                  | `webhook_configs` to `https://ntfy.sh/<topic>?template=alertmanager` (built-in template) | The topic name is the only secret: anyone with it can read or publish. Use a 32+ char random topic, or self-host ntfy |
| Telegram                        | Bot + chat                                          | Native `telegram_configs`                                                                | Free                                                                                                                  |
| Email                           | SMTP relay                                          | Native `email_configs`                                                                   | Needs an SMTP relay                                                                                                   |

Proposed config for ntfy (Pushover is analogous with native
`pushover_configs`):

```yaml
receivers:
    - name: critical-push
      webhook_configs:
          - url_file: /etc/alertmanager/secrets/alertmanager-secret/CRITICAL_PUSH_URL # https://ntfy.sh/<random>?template=alertmanager
            send_resolved: true
route:
    routes:
        # after the Watchdog/InfoInhibitor routes, before the Discord routes
        - receiver: critical-push
          matchers: [severity = critical]
          continue: true
```

It also needs a CNP `toFQDNs: matchName: ntfy.sh` (or `api.pushover.net`) on
443, and a `CRITICAL_PUSH_URL` key in `alertmanager-secret`. Point the
healthchecks.io check at the same app so the phone gets both paths. This is
not implemented here because it needs a choice of app and topic, and it would
widen the conflict with PR #554.

## Rebase notes (PR #554, `feat/loki-ruler-sigma`)

Both PRs edit the same files. Expected conflicts:

- `helmrelease.yaml` receivers: both insert above the `# Uncomment with
kube-agent deployment:` comment. Keep both receivers.
- `ciliumnetworkpolicy.yaml` alertmanager header comment: both rewrite it.
  Merge the wording.
- `justfile`: `mod monitoring` and `mod sigma` sit between `kube` and `talos`.
  Keep both.
- Routes don't overlap (this PR changes only the Watchdog route).
- After both land, switch the Loki ruler `alertmanager_url` to DNS-SRV
  discovery (see HA above).

## Follow-ups

- Narrow the Discord egress from `0.0.0.0/0:443` to `toFQDNs: discord.com`,
  and move `DISCORD_WEBHOOK_URL` to `webhook_url_file` for the same secrecy.
- Spend spare healthchecks.io checks on other "did it run" signals: B2 Cloud
  Sync, etcd snapshot CronJob (B1), monthly restore drill (B2), Kopia
  maintenance.
- blackbox-exporter (`zeroscaler-plan.md`) covers in-cluster DNS/TLS/ICMP
  probes. It complements UptimeRobot but doesn't replace it, since it runs
  inside the thing being monitored.
- If an off-site VPS appears, replace both services with an off-site Gatus
  (the onedr0p/bjw-s pattern).
