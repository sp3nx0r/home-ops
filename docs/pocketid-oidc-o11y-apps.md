# Pocket ID OIDC for internal observability/backup apps

Implements part of **finding #4** ("Internal gateway apps have no authentication")
from [`security-review-and-hardening-plan.md`](./security-review-and-hardening-plan.md).

Puts Pocket ID OIDC (via an Envoy Gateway `SecurityPolicy`) in front of four
internal `envoy-internal` routes that previously had **no gateway auth**:

| App          | Host                           | HTTPRoute (name / ns)                         | SecurityPolicy      | Secret                     |
| ------------ | ------------------------------ | --------------------------------------------- | ------------------- | -------------------------- |
| Thanos       | `thanos.securimancy.com`       | `thanos-query` / `o11y`                       | `thanos-oidc`       | `thanos-oidc-secret`       |
| Kopia        | `kopia.securimancy.com`        | `kopia` / `volsync-system`                    | `kopia-oidc`        | `kopia-oidc-secret`        |
| Prometheus   | `prometheus.securimancy.com`   | `kube-prometheus-stack-prometheus` / `o11y`   | `prometheus-oidc`   | `prometheus-oidc-secret`   |
| Alertmanager | `alertmanager.securimancy.com` | `kube-prometheus-stack-alertmanager` / `o11y` | `alertmanager-oidc` | `alertmanager-oidc-secret` |

Pattern replicated from `kubernetes/apps/media/qui/app/securitypolicy.yaml`.

> **This only affects browser/gateway traffic** to the `*.securimancy.com`
> hostnames above. Machine-to-machine traffic over in-cluster ClusterIP
> Services is unaffected (verified — see the correctness check below).

## ⚠️ Manual Pocket ID steps required before this can merge / work

The committed `SecurityPolicy` files contain **placeholder** client IDs
(`REPLACE_WITH_<APP>_POCKET_ID_CLIENT_ID`) and the secrets contain placeholder
client secrets. Until these are replaced with real Pocket ID values, the OIDC
flow will be broken and **browser access to these four routes will fail**.

For **each** of the four apps:

1. **Create an OIDC client in Pocket ID** (admin UI) for the app.
    - Set the callback / redirect URL **exactly** to:

        | App          | Callback URL                                           |
        | ------------ | ------------------------------------------------------ |
        | Thanos       | `https://thanos.securimancy.com/oauth2/callback`       |
        | Kopia        | `https://kopia.securimancy.com/oauth2/callback`        |
        | Prometheus   | `https://prometheus.securimancy.com/oauth2/callback`   |
        | Alertmanager | `https://alertmanager.securimancy.com/oauth2/callback` |

    - The logout path is `/logout` (intercepted by Envoy Gateway; it need not be
      a real app route).

2. **Copy the client ID** into the app's `securitypolicy.yaml`, replacing the
   `REPLACE_WITH_<APP>_POCKET_ID_CLIENT_ID` placeholder. Client IDs are plaintext
   UUIDs (matching the `qui` reference).

3. **Copy the client secret** into the app's SOPS secret and re-encrypt:

    ```sh
    # edit the client-secret value, then re-encrypt in place
    export SOPS_AGE_KEY_FILE=age.key
    sops --encrypt --in-place <path-to-oidc-secret.sops.yaml>
    ```

    (Or edit through `sops <file>` directly, which re-encrypts on save.)
    The secret's data key is `client-secret` (matches `qui`). Verify the file
    still shows `client-secret: ENC[...]` before committing — never commit a
    plaintext `*.sops.yaml`.

    Secret file paths:
    - `kubernetes/apps/o11y/thanos/app/oidc-secret.sops.yaml`
    - `kubernetes/apps/volsync-system/kopia/app/oidc-secret.sops.yaml`
    - `kubernetes/apps/o11y/kube-prometheus-stack/app/oidc-secret-prometheus.sops.yaml`
    - `kubernetes/apps/o11y/kube-prometheus-stack/app/oidc-secret-alertmanager.sops.yaml`

4. Reconcile Flux (`just reconcile`) and confirm a browser hit to each host is
   redirected through Pocket ID and back.

### Access restrictions (groups)

Pocket ID supports restricting a client to specific user **groups**. If you want
to limit these consoles to an admin group, configure the allowed group(s) on
each OIDC client in Pocket ID. The `SecurityPolicy` already requests the
`groups` scope and sets `forwardAccessToken: true`, so group claims are
available for downstream enforcement if desired.

## Correctness check (why this doesn't break automation)

Gateway OIDC only intercepts traffic arriving via the `*.securimancy.com`
gateway hostnames. All programmatic consumers use in-cluster ClusterIP Services,
so they are unaffected:

- **Grafana datasources** (`kubernetes/apps/o11y/grafana/app/helmrelease.yaml`)
  point at ClusterIP services, not gateway hosts:
    - Prometheus → `http://thanos-query-frontend.o11y.svc.cluster.local:9090`
    - Alertmanager → `http://kube-prometheus-stack-alertmanager.o11y.svc.cluster.local:9093`
- **Prometheus → Alertmanager** alerting is wired by the Prometheus Operator via
  in-cluster Kubernetes service discovery, not the gateway host.
- **Volsync / Kopia**: movers and maintenance connect to the Kopia repository
  directly over **NFS** (`192.168.5.40:/mnt/tank/homelab/kopia`, repo
  `filesystem:///mnt/repository` — see `kubernetes/components/volsync/`). The
  `kopia.securimancy.com` route is only the browse/restore web UI.
- A repo-wide grep for the four gateway hostnames found references only in the
  apps' own route definitions and documentation — **no internal component
  depends on them**.

### Note on `externalUrl`

`prometheus.prometheusSpec.externalUrl` and
`alertmanager.alertmanagerSpec.externalUrl` are set to the gateway hostnames.
These are only used to build **links** (e.g. the `generatorURL` in Discord
alert notifications and links in the UIs). After OIDC, clicking those links in a
browser will require a Pocket ID login — expected for human traffic, not a
breakage of alerting.
