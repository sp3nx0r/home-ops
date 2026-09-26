# Cilium Hubble + Hubble UI

Enable Cilium Hubble (observability layer) and the Hubble UI so network flows,
service maps, and policy verdicts are visible through a web UI, and Hubble
metrics/dashboards land in the existing Prometheus + Grafana stack.

> **Status:** Proposed (PR `feat/cilium-hubble-ui`). Pocket ID client is
> registered and wired in — no blocking manual steps remain.

## Why

The [security hardening plan](./security-review-and-hardening-plan.md) calls out
that Hubble is currently **disabled**, so the in-progress default-deny
`CiliumNetworkPolicy` rollout (#1) has to be validated with
`cilium monitor --type drop --type policy-verdict` on individual nodes. Hubble
gives that same policy-verdict/drop visibility cluster-wide through Relay + UI,
which directly supports finishing the default-deny work — the flow viewer shows
exactly which connections a new policy would break before it's enforced.

## What changed

All changes are in `kubernetes/apps/kube-system/cilium/`.

| File                        | Change                                                                                                                                                    |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `app/helmrelease.yaml`      | `hubble.enabled: true`; enable `relay`, `ui`, Hubble metrics (`enableOpenMetrics`, `serviceMonitor`) and a Grafana dashboard (`grafana_folder: Network`). |
| `app/httproute.yaml`        | New Gateway API `HTTPRoute` `hubble-ui` → `hubble-ui:80` on `envoy-internal`, hostname `hubble.${SECRET_DOMAIN}`.                                         |
| `app/securitypolicy.yaml`   | New Envoy Gateway `SecurityPolicy` `hubble-ui-oidc` gating the route behind Pocket ID OIDC (same pattern as thanos/kopia).                                |
| `app/oidc-secret.sops.yaml` | SOPS-encrypted `hubble-ui-oidc-secret` holding the OIDC client secret.                                                                                    |
| `app/kustomization.yaml`    | Adds the three new resources.                                                                                                                             |

### Hubble config choices

- **Relay + UI enabled**, both with `rollOutPods: true` (consistent with the
  operator/agent rollout flags already set in the HelmRelease).
- **Metrics**: `dns`, `drop`, `tcp`, `flow`, `port-distribution`, `icmp`, and
  `httpV2` context labels — the standard Hubble metric set, with
  `enableOpenMetrics` and a `serviceMonitor` so the existing
  kube-prometheus-stack scrapes them. Relay also exposes a `serviceMonitor`.
- **Grafana dashboard** shipped by the chart into the `Network` folder, matching
  the existing Cilium agent/operator dashboards.
- **TLS**: left at the chart default (`hubble.tls.auto.method: helm`), which
  auto-generates the agent↔relay mTLS certs. No cert-manager wiring needed.

### Exposure / auth

Hubble UI has **no built-in authentication** and exposes the full cluster network
topology and live flows, so it is treated as a sensitive internal data plane
(like Prometheus/Thanos/Kopia). It is therefore:

- Published on `envoy-internal` only (`192.168.5.10`, LAN + private DNS), **not**
  `envoy-external` — no public exposure via the Cloudflare tunnel.
- Gated at the gateway with a Pocket ID OIDC `SecurityPolicy`.

Because it's an `envoy-internal` route, UniFi private DNS syncs
`hubble.${SECRET_DOMAIN}` automatically — no manual `unifi-dns` DNSEndpoint
needed (that's only required for `envoy-external` hosts).

## Pocket ID client

A Pocket ID OIDC client is registered for Hubble UI and wired in:

- `clientID` is set in `securitypolicy.yaml`.
- The client secret is stored (SOPS-encrypted) in `oidc-secret.sops.yaml`.
- Callback URL: `https://hubble.${SECRET_DOMAIN}/oauth2/callback`
- Logout URL: `https://hubble.${SECRET_DOMAIN}/logout`

Confirm the callback/logout URLs above are registered on the Pocket ID client.
(Optional) restrict access to a Pocket ID group via the `groups` claim if the
flat "any authenticated user" default is too broad.

## Validation after reconcile

```sh
just reconcile
kubectl -n kube-system get pods -l k8s-app=hubble-relay
kubectl -n kube-system get pods -l k8s-app=hubble-ui
cilium status                     # Hubble: Ok, Relay: Ok
```

Then browse `https://hubble.${SECRET_DOMAIN}` (Pocket ID login), or use the CLI:

```sh
cilium hubble port-forward &
hubble observe --verdict DROPPED  # useful while rolling out default-deny CNPs
```

## Rollback

Revert the PR (or set `hubble.enabled: false` and drop the three new resources).
Relay/UI are additive and carry no persistent state, so removal is clean.
