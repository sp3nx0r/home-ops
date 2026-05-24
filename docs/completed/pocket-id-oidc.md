# Pocket ID — OIDC Provider

**Pocket ID** is the cluster's OIDC identity provider, providing passkey-based authentication for the whole family with shared SSO cookies across `*.securimancy.com`.

**Tech Stack:** Pocket ID (Go, SQLite), Envoy Gateway SecurityPolicy (per-route OIDC), Grafana native OIDC, Flux GitOps (HelmRelease via app-template), SOPS (secrets), VolSync/Kopia (backups), iSCSI (storage), Garage S3 (file backend)

---

## Architecture

Pocket ID runs as a single-replica deployment with SQLite on an iSCSI PVC, exposed internally via `envoy-internal` at `https://id.securimancy.com`. File uploads and assets are stored in Garage S3 (cluster-local). Prometheus metrics are exported via OpenTelemetry and scraped by a ServiceMonitor.

Apps opt in to OIDC protection using one of two patterns:

1. **Envoy Gateway SecurityPolicy** — A SecurityPolicy resource targets an app's HTTPRoute. Envoy handles the full OIDC code flow (redirect → passkey auth → session cookie). Best for apps with no native OIDC support.
2. **Native OIDC integration** — The app itself handles OIDC (e.g., Grafana's `auth.generic_oauth`). Allows role mapping from Pocket ID groups to app-specific roles.

SSO works across all protected apps via shared `cookieDomain` on `${SECRET_DOMAIN}`.

---

## File Structure

```
kubernetes/apps/security/
├── kustomization.yaml                 # Namespace kustomization (includes sops component)
├── namespace.yaml                     # security namespace
└── pocket-id/
    ├── ks.yaml                        # Flux Kustomization (postBuild, VolSync + Garage deps)
    └── app/
        ├── kustomization.yaml         # App kustomization (includes volsync component)
        ├── helmrelease.yaml           # Pocket ID via app-template
        ├── ocirepository.yaml         # OCI repo for app-template chart
        ├── pvc.yaml                   # 2Gi iSCSI PVC for SQLite
        ├── secret.sops.yaml           # ENCRYPTION_KEY + MAXMIND_LICENSE_KEY
        └── volsync-secret.sops.yaml   # Kopia backup credentials
```

SecurityPolicy resources live alongside the apps they protect:

```
kubernetes/apps/media/qui/app/securitypolicy.yaml
kubernetes/apps/media/qui/app/oidc-secret.sops.yaml
kubernetes/apps/zeroclaw/zeroclaw/app/securitypolicy.yaml
kubernetes/apps/zeroclaw/zeroclaw/app/oidc-secret.sops.yaml
```

Grafana uses native OIDC — no SecurityPolicy. Its client secret is in `grafana-secret`.

---

## Pocket ID Deployment

### Namespace

```yaml
# kubernetes/apps/security/namespace.yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: security
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
```

```yaml
# kubernetes/apps/security/kustomization.yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: security

components:
  - ../../components/sops

resources:
  - ./namespace.yaml
  - ./pocket-id/ks.yaml
```

### Flux Kustomization

```yaml
# kubernetes/apps/security/pocket-id/ks.yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: pocket-id
spec:
  interval: 1h
  path: ./kubernetes/apps/security/pocket-id/app
  postBuild:
    substitute:
      APP: pocket-id
      VOLSYNC_CAPACITY: "2Gi"
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: security
  wait: true
  dependsOn:
    - name: volsync
      namespace: volsync-system
    - name: garage
      namespace: storage
```

Dependencies:
- **volsync** — VolSync operator must be running for Kopia backups
- **garage** — Garage S3 must be running for file backend storage

### OCI Repository

```yaml
# kubernetes/apps/security/pocket-id/app/ocirepository.yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/source.toolkit.fluxcd.io/ocirepository_v1.json
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: pocket-id
spec:
  interval: 15m
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: <current-app-template-version>
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

Uses explicit `ref.tag` (managed by Renovate), not `semver: "*"`.

### PVC

```yaml
# kubernetes/apps/security/pocket-id/app/pvc.yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pocket-id
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: iscsi
  resources:
    requests:
      storage: 2Gi
```

2Gi covers SQLite + GeoLite2 DB. File uploads go to Garage S3, not the PVC.

### Secret

```yaml
# kubernetes/apps/security/pocket-id/app/secret.sops.yaml (structure, encrypted in repo)
---
apiVersion: v1
kind: Secret
metadata:
  name: pocket-id-secret
stringData:
  ENCRYPTION_KEY: "<32-char-hex>"
  MAXMIND_LICENSE_KEY: "<maxmind-key>"
```

- `ENCRYPTION_KEY` — minimum 16 bytes hex, used for internal encryption. Generate with `openssl rand -hex 16`.
- `MAXMIND_LICENSE_KEY` — enables GeoIP login location tracking via GeoLite2.

Encrypt with: `sops --encrypt --in-place kubernetes/apps/security/pocket-id/app/secret.sops.yaml`

### HelmRelease

```yaml
# kubernetes/apps/security/pocket-id/app/helmrelease.yaml
---
# yaml-language-server: $schema=https://raw.githubusercontent.com/bjw-s-labs/helm-charts/main/charts/other/app-template/schemas/helmrelease-helm-v2.schema.json
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: pocket-id
spec:
  chartRef:
    kind: OCIRepository
    name: pocket-id
  interval: 1h
  values:
    controllers:
      pocket-id:
        annotations:
          reloader.stakater.com/auto: "true"
        containers:
          app:
            image:
              repository: ghcr.io/pocket-id/pocket-id
              tag: <current-version>
            env:
              APP_URL: "https://id.${SECRET_DOMAIN}"
              TRUST_PROXY: "true"
              DB_CONNECTION_STRING: "/app/data/pocket-id.db"
              ANALYTICS_DISABLED: "true"
              VERSION_CHECK_DISABLED: "true"
              METRICS_ENABLED: "true"
              OTEL_METRICS_EXPORTER: "prometheus"
              OTEL_EXPORTER_PROMETHEUS_HOST: "0.0.0.0"
              OTEL_EXPORTER_PROMETHEUS_PORT: "9464"
              FILE_BACKEND: "s3"
              S3_BUCKET: "pocket-id"
              S3_REGION: "garage"
              S3_ENDPOINT: "http://garage.storage.svc.cluster.local:3900"
              S3_ACCESS_KEY_ID: "${POCKET_ID_S3_KEY_ID}"
              S3_SECRET_ACCESS_KEY: "${POCKET_ID_S3_SECRET_KEY}"
              S3_FORCE_PATH_STYLE: "true"
            envFrom:
              - secretRef:
                  name: pocket-id-secret
            probes:
              liveness: &probes
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /healthz
                    port: &port 1411
                  initialDelaySeconds: 5
                  periodSeconds: 10
                  timeoutSeconds: 3
                  failureThreshold: 3
              readiness: *probes
            resources:
              requests:
                cpu: 10m
                memory: 64Mi
              limits:
                memory: 256Mi
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: false
              capabilities: {drop: ["ALL"]}
    defaultPodOptions:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        fsGroupChangePolicy: OnRootMismatch
    service:
      app:
        ports:
          http:
            port: *port
          metrics:
            port: 9464
    route:
      app:
        hostnames:
          - "id.${SECRET_DOMAIN}"
        parentRefs:
          - name: envoy-internal
            namespace: network
            sectionName: https
        rules:
          - backendRefs:
              - identifier: app
                port: *port
    serviceMonitor:
      app:
        serviceName: pocket-id
        endpoints:
          - port: metrics
            scheme: http
            path: /metrics
            interval: 1m
            scrapeTimeout: 10s
    persistence:
      data:
        existingClaim: pocket-id
        globalMounts:
          - path: /app/data
```

Key configuration notes:
- `TRUST_PROXY: "true"` — required behind Envoy Gateway
- `readOnlyRootFilesystem: false` — Pocket ID writes to the mounted PVC and may need temp files
- `runAsUser/runAsGroup: 1000` — confirmed working UID/GID for this image
- S3 credentials (`POCKET_ID_S3_KEY_ID`, `POCKET_ID_S3_SECRET_KEY`) are injected from `cluster-secrets` via `postBuild.substituteFrom`
- Image tag is managed by Renovate

### App Kustomization

```yaml
# kubernetes/apps/security/pocket-id/app/kustomization.yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
components:
  - ../../../../components/volsync
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  - ./pvc.yaml
  - ./secret.sops.yaml
  - ./volsync-secret.sops.yaml
```

### VolSync Backup

```yaml
# kubernetes/apps/security/pocket-id/app/volsync-secret.sops.yaml (structure, encrypted in repo)
---
apiVersion: v1
kind: Secret
metadata:
  name: pocket-id-volsync-secret
type: Opaque
stringData:
  KOPIA_PASSWORD: "<generated-password>"
  KOPIA_REPOSITORY: "<kopia-repo-path>"
```

Uses Kopia (not Restic). The `volsync` component in `kustomization.yaml` creates the `ReplicationSource` automatically using `${APP}` and `${VOLSYNC_CAPACITY}` from the Flux Kustomization's `postBuild.substitute`.

Pocket ID's SQLite database contains passkeys, OIDC clients, and user data — losing it means re-registering every user and every OIDC client. Backups are essential.

---

## Initial Setup

After deploying Pocket ID:

1. Open `https://id.securimancy.com`
2. Complete the initial admin setup — register the first passkey (this becomes the admin user)
3. Create user accounts for family members under Users → Add User
4. Optionally create groups (e.g., `admins`, `family`, `grafana_admin`) for role-based access

---

## Protecting Apps with OIDC

### Pattern 1: Envoy Gateway SecurityPolicy

For apps without native OIDC support. Envoy handles the full OIDC code flow at the gateway level.

**Per-app requirements:**
1. Register an OIDC client in the Pocket ID admin UI
2. Create an OIDC client secret (SOPS-encrypted)
3. Create a SecurityPolicy targeting the app's HTTPRoute
4. Update the app's kustomization to include both resources
5. Ensure the app's `ks.yaml` has `postBuild.substituteFrom` for `cluster-secrets` (needed for `${SECRET_DOMAIN}`)

**OIDC client secret:**

```yaml
# kubernetes/apps/<namespace>/<app>/app/oidc-secret.sops.yaml (before encryption)
---
apiVersion: v1
kind: Secret
metadata:
  name: <app>-oidc-secret
stringData:
  client-secret: "<client-secret-from-pocket-id>"
```

**SecurityPolicy:**

```yaml
# kubernetes/apps/<namespace>/<app>/app/securitypolicy.yaml
---
# yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.envoyproxy.io/securitypolicy_v1alpha1.json
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: <app>-oidc
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <httproute-name>
  oidc:
    provider:
      issuer: "https://id.${SECRET_DOMAIN}"
    clientID: "<client-id-from-pocket-id>"
    clientSecret:
      name: <app>-oidc-secret
    redirectURL: "https://<app-hostname>.${SECRET_DOMAIN}/oauth2/callback"
    logoutPath: "/logout"
    cookieDomain: "${SECRET_DOMAIN}"
    cookieNames:
      idToken: <app>-id-token
      accessToken: <app>-access-token
    forwardAccessToken: true
    scopes:
      - openid
      - profile
      - email
      - groups
```

Key fields:
- `targetRefs.name` — must match the actual HTTPRoute name. Verify with `kubectl get httproute -n <namespace>`.
- `cookieDomain: "${SECRET_DOMAIN}"` — enables SSO across all subdomains
- `cookieNames` — unique per app to prevent cookie collisions across shared domain
- `forwardAccessToken: true` — passes the bearer token to the backend

**Kustomization update** — add both resources:

```yaml
resources:
  # ...existing resources...
  - ./oidc-secret.sops.yaml
  - ./securitypolicy.yaml
```

### Pattern 2: Native OIDC (Grafana)

Grafana uses its built-in `auth.generic_oauth` for OIDC, which enables role mapping from Pocket ID groups to Grafana roles.

In `grafana-secret` (SOPS-encrypted):
- `GRAFANA_OIDC_CLIENT_SECRET` — the OIDC client secret from Pocket ID

In the Grafana HelmRelease `grafana.ini`:

```yaml
auth.generic_oauth:
  enabled: true
  name: PocketID
  client_id: <client-id-from-pocket-id>
  client_secret: $__env{GRAFANA_OIDC_CLIENT_SECRET}
  scopes: openid profile email groups
  auth_url: https://id.securimancy.com/authorize
  token_url: https://id.securimancy.com/api/oidc/token
  api_url: https://id.securimancy.com/api/oidc/userinfo
  use_pkce: false
  allow_sign_up: true
  auto_login: true
  role_attribute_path: contains(groups[*], 'grafana_admin') && 'GrafanaAdmin' || 'Viewer'
```

- `auto_login: true` — skips the Grafana login page, redirects straight to Pocket ID
- `role_attribute_path` — users in the `grafana_admin` group get `GrafanaAdmin` role; everyone else gets `Viewer`
- Domain is hardcoded (not `${SECRET_DOMAIN}`) since Grafana's `ks.yaml` doesn't use `postBuild.substituteFrom`

---

## Apps Currently Using OIDC

| App | Namespace | Pattern | Notes |
|-----------|-----------|-------------------------|-------------------------------------------|
| Grafana | o11y | Native `generic_oauth` | Role mapping via `grafana_admin` group |
| Qui | media | Envoy SecurityPolicy | Gateway-level OIDC |
| Zeroclaw | zeroclaw | Envoy SecurityPolicy | Gateway-level OIDC |

Apps without SecurityPolicies (e.g., Plex, Headlamp, OpenWebUI) remain accessible without authentication.

---

## Observability

Pocket ID exports Prometheus metrics via OpenTelemetry:
- Metrics endpoint: port `9464`, path `/metrics`
- ServiceMonitor scrapes every 1m
- Dashboards: accessible in Grafana via the Prometheus datasource

---

## Troubleshooting

### OIDC redirect failures
1. Verify the SecurityPolicy is accepted: `kubectl get securitypolicy -n <namespace> <name> -o yaml`
2. Check Envoy Gateway logs: `kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway`
3. Confirm the Pocket ID callback URL matches `redirectURL` exactly
4. Confirm the HTTPRoute name in `targetRefs` matches: `kubectl get httproute -n <namespace>`

### Pocket ID pod issues
```bash
kubectl get pods -n security -l app.kubernetes.io/name=pocket-id
kubectl logs -n security -l app.kubernetes.io/name=pocket-id -f
```

### VolSync backup verification
```bash
kubectl get replicationsource -n security
```

---

## Future Enhancements

- **SQLite → PostgreSQL migration:** Use `pocket-id export`, switch `DB_CONNECTION_STRING` to `postgres://...`, `pocket-id import`. See [Discussion #980](https://github.com/pocket-id/pocket-id/discussions/980).
- **External gateway protection:** Add SecurityPolicies for externally-exposed apps that should require auth.
- **LDAP sync:** Pocket ID supports LDAP user/group sync if a directory service is added.
- **Additional app protection:** Headlamp, OpenWebUI, and other internal apps can be protected by adding SecurityPolicies following the template above.
