# Alertmanager changes

## Where things live

- `kubernetes/apps/o11y/kube-prometheus-stack/app/helmrelease.yaml`: `.spec.values.alertmanager.config` (receivers, `route.routes`). `alertmanager.alertmanagerSpec` is the Alertmanager CR spec (replicas, secrets, externalUrl).
- `kubernetes/apps/o11y/kube-prometheus-stack/ks.yaml` `substituteFrom`: `alertmanager-secret` (`app/secret.sops.yaml`) **and** `cluster-secrets`. Receiver secrets belong in `alertmanager-secret`, not `cluster-secrets` (copied to every namespace).
- CNP `alertmanager` in `app/ciliumnetworkpolicy.yaml`.
- Open PRs touching this HR: [#559](https://github.com/sp3nx0r/home-ops/pull/559) (heartbeat/HA). Check `gh pr diff <n> --name-only` before editing.

## Live facts (read-only)

```sh
kubectl -n o11y get alertmanager -o jsonpath='{range .items[*]}{.metadata.name} {.spec.version} replicas={.spec.replicas}{"\n"}{end}'
kubectl -n o11y get prometheus kube-prometheus-stack -o jsonpath='eval={.spec.evaluationInterval}{"\n"}'
yq '.spec.ref.tag' kubernetes/apps/o11y/kube-prometheus-stack/app/ocirepository.yaml
```

## Secrets

```sh
sops set kubernetes/apps/o11y/kube-prometheus-stack/app/secret.sops.yaml '["stringData"]["HEARTBEAT_PING_URL"]' '"https://heartbeat.invalid/REPLACE"'
sops -d kubernetes/apps/o11y/kube-prometheus-stack/app/secret.sops.yaml | yq '.stringData | keys'
```

To keep a URL out of the HelmRelease object, mount the secret and use `url_file` / `webhook_url_file`:

```yaml
alertmanagerSpec:
    secrets: [alertmanager-secret] # → /etc/alertmanager/secrets/alertmanager-secret/<key>
# receiver
webhook_configs:
    - url_file: /etc/alertmanager/secrets/alertmanager-secret/HEARTBEAT_PING_URL
      send_resolved: false
```

`url_file` is re-read on each notify, so rotation needs no reload.

## Render and validate

Release name must be `kube-prometheus-stack`; otherwise the Secret name differs and the select returns nothing (empty file, confusing amtool failure).

```sh
V=$(yq '.spec.ref.tag' kubernetes/apps/o11y/kube-prometheus-stack/app/ocirepository.yaml)
helm pull oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack --version "$V" --untar -d /tmp/kps
kustomize build kubernetes/apps/o11y/kube-prometheus-stack/app | yq 'select(.kind=="HelmRelease") | .spec.values' \
  | sed 's/\${SECRET_DOMAIN}/example.com/g; s#\${DISCORD_WEBHOOK_URL}#https://discord.invalid/api/webhooks/0/x#g' > /tmp/kps-values.yaml
rg -o '\$\{[A-Z_]*\}' /tmp/kps-values.yaml          # must print nothing; add a sed per new var
helm template kube-prometheus-stack /tmp/kps/kube-prometheus-stack -n o11y -f /tmp/kps-values.yaml \
  | yq 'select(.kind=="Secret" and .metadata.name=="alertmanager-kube-prometheus-stack") | .data."alertmanager.yaml"' | base64 -d > /tmp/am.yaml
amtool check-config /tmp/am.yaml; echo rc=$?     # check the exit code, not the last line
for t in "alertname=Watchdog severity=none" "alertname=KubeNodeNotReady severity=warning node=x" \
         "alertname=Foo severity=critical namespace=x" "alertname=Bar severity=info"; do
  echo "$t → $(amtool config routes test --config.file=/tmp/am.yaml $t)"; done
# today: Watchdog → blackhole, KubeNodeNotReady → discord (node route), Foo → discord, Bar → blackhole
rm -rf /tmp/kps /tmp/kps-values.yaml /tmp/am.yaml
```

The operator doesn't webhook-validate the raw config; a bad config only shows as the operator refusing to reconcile. amtool is the gate.

## Routing rules

- New specific routes go **before** the generic `severity =~ critical|warning` Discord route; first match wins unless `continue: true`.
- Every new external receiver gets a `toFQDNs` + 443/TCP egress rule in the `alertmanager` CNP, even if the broad 443 rule already covers it; update the header comment.

## Semantics (verified against v0.34.1 source)

- **`repeat_interval == group_interval` resends only every other tick.** Dedup compares the nflog timestamp (written after the send returns) with flush tick minus repeat_interval. For a heartbeat that must fire every tick, use `repeat_interval < group_interval` (e.g. `group_wait: 0s`, `group_interval: 1m`, `repeat_interval: 50s`). amtool doesn't warn.
- **Heartbeat receivers need `send_resolved: false`**; otherwise a dead Prometheus resolves Watchdog and the resolved POST looks like a ping.
- Dead-Prometheus detection latency ≈ 4 × max(eval_interval, 1m) + the external period + grace.
- **An unfilled placeholder URL** makes every send fail, which fires critical `AlertmanagerClusterFailedToSendAlerts` to Discord. Fill it before merge; use `.invalid` hosts.
- A heartbeat doesn't prove Discord delivery. Mention a second channel.
- Configure external heartbeat checks as POST-only so link previews can't fake pings.

## HA (replicas: 2)

- Storage is emptyDir: one replica loses silences and nflog on each restart; two replicas gossip them.
- CNP: ingress **and** egress `9094` TCP **and** UDP between `app.kubernetes.io/name: alertmanager` pods (memberlist).
- `alertmanager.podDisruptionBudget.enabled: true` (minAvailable 1); check `kubectl get pdb -A` so Tuppr drains aren't blocked.
- Alerts are not gossiped: every sender must hit all pods. Prometheus does (endpoint discovery). Other senders (Loki ruler) must use `dnssrvnoa+http://_http-web._tcp.alertmanager-operated.o11y.svc.cluster.local`.
