# PocketID OIDC Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy PocketID as the cluster's OIDC identity provider with Envoy Gateway SecurityPolicy for selective per-route authentication.

**Architecture:** PocketID runs as a single-replica deployment with SQLite on an iSCSI PVC, exposed via `envoy-internal`. Envoy Gateway's native OIDC SecurityPolicy protects individual HTTPRoutes — each app opts in by adding a SecurityPolicy targeting its route. Passkey-based auth for the whole family with shared SSO cookies across `*.securimancy.com`.

**Tech Stack:** PocketID (Go, SQLite), Envoy Gateway SecurityPolicy (native OIDC), Flux GitOps (HelmRelease via app-template), SOPS (secrets), VolSync (backups), iSCSI (storage)

---

## File Structure

```
kubernetes/apps/security/                          # New namespace for auth infrastructure
├── kustomization.yaml                             # Namespace-level kustomization
├── namespace.yaml                                 # security namespace
└── pocket-id/
    ├── ks.yaml                                    # Flux Kustomization
    └── app/
        ├── kustomization.yaml                     # App-level kustomization
        ├── helmrelease.yaml                       # PocketID via app-template
        ├── ocirepository.yaml                     # OCI repo for app-template chart
        ├── pvc.yaml                               # iSCSI PVC for SQLite + uploads
        └── secret.sops.yaml                       # SOPS-encrypted ENCRYPTION_KEY + APP_URL
```

SecurityPolicy resources live alongside the apps they protect (not centralized), because each app's route definition and auth policy belong together:

```
kubernetes/apps/o11y/grafana/app/securitypolicy.yaml
kubernetes/apps/o11y/headlamp/app/securitypolicy.yaml
kubernetes/apps/default/openwebui/app/securitypolicy.yaml
...etc (one per app that opts in)
```

Each SecurityPolicy needs a corresponding OIDC client registered in PocketID with the correct redirect URL. The client secret for each is stored as a Kubernetes Secret (SOPS-encrypted) in the same app directory.

---

### Task 1: Create the `security` Namespace and Flux Wiring

**Files:**
- Create: `kubernetes/apps/security/namespace.yaml`
- Create: `kubernetes/apps/security/kustomization.yaml`

- [ ] **Step 1: Create the namespace manifest**

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

- [ ] **Step 2: Create the namespace-level kustomization**

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

- [ ] **Step 3: Verify auto-discovery works**

There is no top-level `kubernetes/apps/kustomization.yaml` — the Flux `cluster-apps` Kustomization (`kubernetes/flux/cluster/ks.yaml`) uses `path: ./kubernetes/apps` and Kustomize auto-discovers subdirectories that contain a `kustomization.yaml`. Creating `kubernetes/apps/security/kustomization.yaml` is sufficient — no registration step needed.

Verify this by checking that other namespace directories (e.g. `storage/`, `o11y/`) follow the same pattern: a directory with a `kustomization.yaml` that lists its namespace resource and child `ks.yaml` files.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/apps/security/namespace.yaml kubernetes/apps/security/kustomization.yaml
git commit -m "feat(security): add security namespace for auth infrastructure"
```

---

### Task 2: Create the PocketID Flux Kustomization

**Files:**
- Create: `kubernetes/apps/security/pocket-id/ks.yaml`

- [ ] **Step 1: Create the Flux Kustomization for PocketID**

This follows the same pattern as other apps (e.g. `kubernetes/apps/o11y/grafana/ks.yaml`). It uses `postBuild.substituteFrom` to access `cluster-secrets` for `SECRET_DOMAIN`.

```yaml
# kubernetes/apps/security/pocket-id/ks.yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: pocket-id
spec:
  interval: 1h
  path: ./kubernetes/apps/security/pocket-id/app
  postBuild:
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
```

`wait: true` so downstream SecurityPolicies can depend on PocketID being ready.

- [ ] **Step 2: Commit**

```bash
git add kubernetes/apps/security/pocket-id/ks.yaml
git commit -m "feat(pocket-id): add Flux Kustomization"
```

---

### Task 3: Create the PocketID OCI Repository and PVC

**Files:**
- Create: `kubernetes/apps/security/pocket-id/app/ocirepository.yaml`
- Create: `kubernetes/apps/security/pocket-id/app/pvc.yaml`

- [ ] **Step 1: Create the OCI repository for app-template**

Check an existing app for the exact OCI repository URL and tag pattern. For example, look at `kubernetes/apps/default/openwebui/app/ocirepository.yaml` and use the same `app-template` chart reference:

```yaml
# kubernetes/apps/security/pocket-id/app/ocirepository.yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/source.toolkit.fluxcd.io/ocirepository_v1beta2.json
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: pocket-id
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    semver: "*"
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

Verify the exact `url` and `ref` fields match other app-template OCIRepositories in the repo (e.g. `openwebui`, `sonarr`). They should all point at the same chart.

- [ ] **Step 2: Create the iSCSI PVC**

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

2Gi is plenty for SQLite + uploads + GeoLite2 DB.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/security/pocket-id/app/ocirepository.yaml kubernetes/apps/security/pocket-id/app/pvc.yaml
git commit -m "feat(pocket-id): add OCI repository and iSCSI PVC"
```

---

### Task 4: Create the PocketID Secret

**Files:**
- Create: `kubernetes/apps/security/pocket-id/app/secret.sops.yaml`

- [ ] **Step 1: Generate the encryption key**

PocketID requires an `ENCRYPTION_KEY` of at least 16 bytes. Generate one:

```bash
openssl rand -hex 16
```

- [ ] **Step 2: Create the SOPS secret**

Create the plaintext secret, then encrypt it with SOPS. The `age` recipient is `age1j8auc0sy76etmugnrnqv7j0v9de5l9ffswnqj7ndrzqndh5rdpjq5atgj8` (from `kubernetes/components/sops/cluster-secrets.sops.yaml`).

```yaml
# kubernetes/apps/security/pocket-id/app/secret.sops.yaml (before encryption)
---
apiVersion: v1
kind: Secret
metadata:
  name: pocket-id-secret
stringData:
  ENCRYPTION_KEY: "<generated-hex-value>"
```

Encrypt:

```bash
sops --encrypt --age age1j8auc0sy76etmugnrnqv7j0v9de5l9ffswnqj7ndrzqndh5rdpjq5atgj8 \
  --encrypted-regex '^(data|stringData)$' \
  --in-place kubernetes/apps/security/pocket-id/app/secret.sops.yaml
```

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/security/pocket-id/app/secret.sops.yaml
git commit -m "feat(pocket-id): add SOPS-encrypted secret"
```

---

### Task 5: Create the PocketID HelmRelease

**Files:**
- Create: `kubernetes/apps/security/pocket-id/app/helmrelease.yaml`

- [ ] **Step 1: Create the HelmRelease**

This uses the bjw-s `app-template` chart, same pattern as OpenWebUI and other apps. PocketID's container image is `ghcr.io/pocket-id/pocket-id`, listens on port 1411, and persists data at `/app/data`.

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
              tag: v2.6.2
            env:
              APP_URL: "https://id.${SECRET_DOMAIN}"
              TRUST_PROXY: "true"
              MAXMIND_LICENSE_KEY: ""
              DB_CONNECTION_STRING: "data/pocket-id.db"
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
    persistence:
      data:
        existingClaim: pocket-id
        globalMounts:
          - path: /app/data
```

Key configuration notes:
- `APP_URL` uses `id.${SECRET_DOMAIN}` — PocketID will be at `https://id.securimancy.com`
- `TRUST_PROXY: "true"` because it sits behind Envoy Gateway
- `readOnlyRootFilesystem: false` because PocketID writes to `/app/data` (mounted PVC) and may need temp files
- `MAXMIND_LICENSE_KEY` is empty to disable GeoIP (optional, add later if you want login location info)
- Check the latest PocketID tag on `ghcr.io/pocket-id/pocket-id` and update `tag` accordingly
- The `runAsUser`/`runAsGroup` may need adjustment — verify the PocketID container's expected UID. Check the Dockerfile or run the image to confirm. The distroless image runs as `nonroot` (UID 65534). If so, change `runAsUser: 65534` and `runAsGroup: 65534`.

- [ ] **Step 2: Commit**

```bash
git add kubernetes/apps/security/pocket-id/app/helmrelease.yaml
git commit -m "feat(pocket-id): add HelmRelease with app-template"
```

---

### Task 6: Create the App-Level Kustomization and Deploy

**Files:**
- Create: `kubernetes/apps/security/pocket-id/app/kustomization.yaml`

- [ ] **Step 1: Create the app kustomization**

```yaml
# kubernetes/apps/security/pocket-id/app/kustomization.yaml
---
# yaml-language-server: $schema=https://json.schemastore.org/kustomization
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  - ./pvc.yaml
  - ./secret.sops.yaml
```

- [ ] **Step 2: Commit and push**

```bash
git add kubernetes/apps/security/pocket-id/app/kustomization.yaml
git commit -m "feat(pocket-id): add app kustomization, ready for deployment"
git push
```

- [ ] **Step 3: Verify PocketID deploys successfully**

Wait for Flux to reconcile, then verify:

```bash
kubectl get pods -n security -w
kubectl logs -n security -l app.kubernetes.io/name=pocket-id -f
```

Expected: Pod reaches `Running` state, health checks pass at `/healthz`.

- [ ] **Step 4: Access PocketID and complete initial setup**

Open `https://id.securimancy.com` in a browser. PocketID will prompt you to create the initial admin account with a passkey. Register your passkey here — this becomes the admin user.

- [ ] **Step 5: Commit any fixes**

If you needed to adjust `runAsUser`, image tag, or other values, commit those fixes now.

---

### Task 7: Register the First OIDC Client (Grafana) in PocketID

This task is done via the PocketID admin UI, not GitOps. Each app that will be OIDC-protected needs a client registration.

**Files:**
- Create: `kubernetes/apps/o11y/grafana/app/oidc-secret.sops.yaml`

- [ ] **Step 1: Create an OIDC client in PocketID for Grafana**

In the PocketID admin UI (`https://id.securimancy.com`):
1. Go to OIDC Clients
2. Create a new client:
   - **Name:** `Grafana`
   - **Callback URL:** `https://grafana.securimancy.com/oauth2/callback`
   - **Logout URL:** `https://grafana.securimancy.com/logout`
3. Note the generated **Client ID** and **Client Secret**

- [ ] **Step 2: Create the OIDC client secret for Envoy Gateway**

Envoy Gateway's SecurityPolicy expects a Secret with key `client-secret`:

```yaml
# kubernetes/apps/o11y/grafana/app/oidc-secret.sops.yaml (before encryption)
---
apiVersion: v1
kind: Secret
metadata:
  name: grafana-oidc-secret
stringData:
  client-secret: "<client-secret-from-pocket-id>"
```

Encrypt with SOPS:

```bash
sops --encrypt --age age1j8auc0sy76etmugnrnqv7j0v9de5l9ffswnqj7ndrzqndh5rdpjq5atgj8 \
  --encrypted-regex '^(data|stringData)$' \
  --in-place kubernetes/apps/o11y/grafana/app/oidc-secret.sops.yaml
```

- [ ] **Step 3: Commit**

```bash
git add kubernetes/apps/o11y/grafana/app/oidc-secret.sops.yaml
git commit -m "feat(grafana): add OIDC client secret for Envoy SecurityPolicy"
```

---

### Task 8: Add Envoy Gateway SecurityPolicy for Grafana

**Files:**
- Create: `kubernetes/apps/o11y/grafana/app/securitypolicy.yaml`
- Modify: `kubernetes/apps/o11y/grafana/app/kustomization.yaml`
- Modify: `kubernetes/apps/o11y/grafana/ks.yaml`

- [ ] **Step 1: Add `postBuild.substituteFrom` to Grafana's Flux Kustomization**

The Grafana `ks.yaml` currently lacks `postBuild.substituteFrom` for `cluster-secrets` (unlike media apps which have it). The SecurityPolicy needs `${SECRET_DOMAIN}` substitution. Update `kubernetes/apps/o11y/grafana/ks.yaml` from:

```yaml
spec:
  dependsOn:
    - name: kube-prometheus-stack
  interval: 1h
  path: ./kubernetes/apps/o11y/grafana/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: o11y
  wait: false
```

To:

```yaml
spec:
  dependsOn:
    - name: kube-prometheus-stack
    - name: pocket-id
  interval: 1h
  path: ./kubernetes/apps/o11y/grafana/app
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: o11y
  wait: false
```

This adds both `substituteFrom` (for `${SECRET_DOMAIN}`) and a dependency on `pocket-id` (so the OIDC provider is up before the SecurityPolicy is applied).

- [ ] **Step 2: Create the SecurityPolicy**

This SecurityPolicy targets the Grafana HTTPRoute specifically (not the entire Gateway). Envoy Gateway handles the full OIDC code flow — browser gets redirected to PocketID for passkey auth, then back to Grafana with a session cookie.

```yaml
# kubernetes/apps/o11y/grafana/app/securitypolicy.yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/gateway.envoyproxy.io/securitypolicy_v1alpha1.json
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: grafana-oidc
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: grafana
  oidc:
    provider:
      issuer: "https://id.${SECRET_DOMAIN}"
    clientID: "<client-id-from-pocket-id>"
    clientSecret:
      name: grafana-oidc-secret
    redirectURL: "https://grafana.${SECRET_DOMAIN}/oauth2/callback"
    logoutPath: "/logout"
    cookieDomain: "${SECRET_DOMAIN}"
    cookieNameOverrides:
      - name: IdToken
        value: grafana-id-token
      - name: AccessToken
        value: grafana-access-token
    forwardAccessToken: true
    scopes:
      - openid
      - profile
      - email
      - groups
```

Key decisions:
- `cookieDomain: "${SECRET_DOMAIN}"` enables SSO across all `*.securimancy.com` subdomains — login once via PocketID, authenticated everywhere
- `forwardAccessToken: true` passes the bearer token to Grafana in case you later want Grafana to read user identity from the token
- `cookieNameOverrides` prevents cookie collisions when multiple apps share the same domain — each app uses unique cookie names
- `targetRefs` targets the HTTPRoute named `grafana`, not the Gateway — only Grafana is protected, other routes are unaffected
- Replace `<client-id-from-pocket-id>` with the actual client ID from PocketID admin UI

Important: The HTTPRoute `name` referenced in `targetRefs` must match the actual HTTPRoute name created by the Grafana HelmRelease. The Grafana HelmRelease uses the Grafana chart (not app-template), so its route is defined inline under `route.main`. Verify the generated HTTPRoute name with `kubectl get httproute -n o11y` after Grafana is deployed, and adjust the `targetRefs.name` accordingly.

- [ ] **Step 3: Add the new resources to the Grafana kustomization**

The current `kubernetes/apps/o11y/grafana/app/kustomization.yaml` has:

```yaml
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  - ./secret.sops.yaml
```

Add the two new resources to the `resources` list:

```yaml
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  - ./secret.sops.yaml
  - ./oidc-secret.sops.yaml
  - ./securitypolicy.yaml
```

Leave the `configMapGenerator` and `generatorOptions` sections unchanged.

- [ ] **Step 4: Commit and push**

```bash
git add kubernetes/apps/o11y/grafana/app/securitypolicy.yaml kubernetes/apps/o11y/grafana/app/kustomization.yaml kubernetes/apps/o11y/grafana/ks.yaml
git commit -m "feat(grafana): add Envoy Gateway OIDC SecurityPolicy"
git push
```

- [ ] **Step 5: Verify OIDC flow works**

1. Open a private/incognito browser window
2. Navigate to `https://grafana.securimancy.com`
3. Expected: Browser redirects to `https://id.securimancy.com` → PocketID passkey prompt → authenticate → redirect back to Grafana, now logged in
4. Verify the session cookie is set on `.securimancy.com` domain

If the redirect fails, check:
- `kubectl get securitypolicy -n o11y grafana-oidc -o yaml` — verify it's accepted
- `kubectl logs -n envoy-gateway-system -l app.kubernetes.io/name=envoy-gateway` — look for OIDC errors
- The PocketID client callback URL matches `redirectURL` exactly
- The HTTPRoute name in `targetRefs` matches the actual HTTPRoute

---

### Task 9: Template for Protecting Additional Apps

This is the repeatable pattern for any app you want to protect. Each app needs:

1. An OIDC client registered in PocketID admin UI
2. A Secret with the client secret (SOPS-encrypted)
3. A SecurityPolicy targeting the app's HTTPRoute
4. The kustomization updated to include the new resources

**Files (per app):**
- Create: `kubernetes/apps/<namespace>/<app>/app/oidc-secret.sops.yaml`
- Create: `kubernetes/apps/<namespace>/<app>/app/securitypolicy.yaml`
- Modify: `kubernetes/apps/<namespace>/<app>/app/kustomization.yaml`

- [ ] **Step 1: Document the pattern**

For each additional app (e.g. Headlamp, OpenWebUI), the SecurityPolicy follows this template:

```yaml
---
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
    clientID: "<client-id>"
    clientSecret:
      name: <app>-oidc-secret
    redirectURL: "https://<app>.${SECRET_DOMAIN}/oauth2/callback"
    logoutPath: "/logout"
    cookieDomain: "${SECRET_DOMAIN}"
    cookieNameOverrides:
      - name: IdToken
        value: <app>-id-token
      - name: AccessToken
        value: <app>-access-token
    forwardAccessToken: true
    scopes:
      - openid
      - profile
      - email
      - groups
```

The OIDC client secret template:

```yaml
---
apiVersion: v1
kind: Secret
metadata:
  name: <app>-oidc-secret
stringData:
  client-secret: "<value>"
```

- [ ] **Step 2: Protect Headlamp**

Repeat the pattern from Task 7–8 for Headlamp:
1. Register OIDC client in PocketID with callback `https://headlamp.securimancy.com/oauth2/callback`
2. Create `kubernetes/apps/o11y/headlamp/app/oidc-secret.sops.yaml`
3. Create `kubernetes/apps/o11y/headlamp/app/securitypolicy.yaml` targeting the Headlamp HTTPRoute
4. Update `kubernetes/apps/o11y/headlamp/app/kustomization.yaml`
5. Verify the HTTPRoute name — Headlamp uses its own chart (not app-template), so check `kubectl get httproute -n o11y` for the actual name

- [ ] **Step 3: Protect OpenWebUI**

Same pattern for OpenWebUI:
1. Register OIDC client in PocketID with callback `https://chat.securimancy.com/oauth2/callback`
2. Create `kubernetes/apps/default/openwebui/app/oidc-secret.sops.yaml`
3. Create `kubernetes/apps/default/openwebui/app/securitypolicy.yaml`
4. Update `kubernetes/apps/default/openwebui/app/kustomization.yaml`

- [ ] **Step 4: Commit all**

```bash
git add kubernetes/apps/o11y/headlamp/app/ kubernetes/apps/default/openwebui/app/
git commit -m "feat: add OIDC protection for Headlamp and OpenWebUI"
git push
```

---

### Task 10: Add VolSync Backup for PocketID

**Files:**
- Create: `kubernetes/apps/security/pocket-id/app/volsync-secret.sops.yaml`
- Modify: `kubernetes/apps/security/pocket-id/app/kustomization.yaml`
- Modify: `kubernetes/apps/security/pocket-id/ks.yaml`

PocketID's SQLite database contains passkeys, OIDC clients, and user data — losing it means re-registering every user and every OIDC client. VolSync backup is essential.

- [ ] **Step 1: Create the VolSync secret**

Follow the same pattern as other VolSync-backed apps (e.g. `kubernetes/apps/media/sonarr/app/volsync-secret.sops.yaml`). Check an existing one for the expected keys (typically `RESTIC_REPOSITORY`, `RESTIC_PASSWORD`, and S3/repository target):

```yaml
# kubernetes/apps/security/pocket-id/app/volsync-secret.sops.yaml (before encryption)
---
apiVersion: v1
kind: Secret
metadata:
  name: pocket-id-volsync
stringData:
  RESTIC_REPOSITORY: "<your-restic-repo-path>/pocket-id"
  RESTIC_PASSWORD: "<generated-password>"
```

Copy the repository pattern from an existing app's volsync secret (e.g. Sonarr's) and adjust the path suffix. Encrypt with SOPS.

- [ ] **Step 2: Add VolSync component to kustomization**

Update `kubernetes/apps/security/pocket-id/app/kustomization.yaml` to include the VolSync component and secret:

```yaml
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

- [ ] **Step 3: Add VolSync dependency and postBuild vars to ks.yaml**

Update `kubernetes/apps/security/pocket-id/ks.yaml` to add the VolSync dependency and the `APP` / `VOLSYNC_CAPACITY` substitution variables that the VolSync component expects:

```yaml
---
# yaml-language-server: $schema=https://kubernetes-schemas.pages.dev/kustomize.toolkit.fluxcd.io/kustomization_v1.json
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
```

- [ ] **Step 4: Commit and push**

```bash
git add kubernetes/apps/security/pocket-id/
git commit -m "feat(pocket-id): add VolSync backup for SQLite data"
git push
```

- [ ] **Step 5: Verify VolSync ReplicationSource is created**

```bash
kubectl get replicationsource -n security
```

Expected: A ReplicationSource for `pocket-id` appears and completes its first snapshot.

---

### Task 11: Add PocketID Family Members

This is done via the PocketID admin UI after deployment.

- [ ] **Step 1: Create user accounts for family members**

In PocketID admin UI (`https://id.securimancy.com`):
1. Go to Users → Add User
2. For each family member, create an account with their name and email
3. They will receive a one-time login code (or you can share a setup link)
4. Each person registers their own passkey on their device(s)

- [ ] **Step 2: Create user groups (optional)**

If you want role-based access (e.g. only admins can access Headlamp):
1. Go to Groups → Create Group (e.g. `admins`, `family`)
2. Assign users to groups
3. On OIDC clients, restrict which groups can authorize
4. The `groups` scope in SecurityPolicy will pass group membership to downstream apps

- [ ] **Step 3: Verify family members can authenticate**

Have each family member:
1. Open a protected app (e.g. Grafana)
2. Get redirected to PocketID
3. Authenticate with their passkey
4. Verify they land on the app successfully
5. Verify SSO works — navigate to another protected app without re-authenticating (shared `cookieDomain`)

---

### Task 12: Verify End-to-End and Document

- [ ] **Step 1: Test the full authentication flow**

Checklist:
- [ ] PocketID is accessible at `https://id.securimancy.com`
- [ ] Admin can log in with passkey
- [ ] Grafana redirects to PocketID when unauthenticated
- [ ] After PocketID auth, Grafana loads successfully
- [ ] SSO works across apps (auth once, access multiple protected apps)
- [ ] Unprotected apps (e.g. Plex, any app without a SecurityPolicy) remain accessible without auth
- [ ] VolSync backup completes successfully

- [ ] **Step 2: Test from external gateway (if applicable)**

If you add a SecurityPolicy targeting an HTTPRoute on `envoy-external`:
- Verify the OIDC redirect works through Cloudflare Tunnel
- PocketID must be reachable from the internet (or the external callback must work)

- [ ] **Step 3: Document which apps are protected**

Add a comment to `kubernetes/apps/security/pocket-id/ks.yaml` or a note in docs listing which apps have SecurityPolicies and which are open.

- [ ] **Step 4: Final commit**

```bash
git add -A
git commit -m "feat(pocket-id): complete OIDC setup with Envoy Gateway SecurityPolicy"
git push
```

---

## Future Enhancements (Not in This Plan)

- **SQLite → PostgreSQL migration:** Use `pocket-id export`, switch `DB_CONNECTION_STRING` to `postgres://...`, `pocket-id import`. See [Discussion #980](https://github.com/pocket-id/pocket-id/discussions/980).
- **Grafana native OIDC:** In addition to gateway-level auth, configure Grafana's `auth.generic_oauth` to map PocketID users/groups to Grafana roles (Editor, Admin, etc.).
- **External gateway protection:** Add SecurityPolicies for externally-exposed apps that should require auth.
- **GeoIP login alerts:** Set `MAXMIND_LICENSE_KEY` for login location tracking.
- **LDAP sync:** If you later add a directory service, PocketID supports LDAP user/group sync.
- **Monitoring:** Add a ServiceMonitor for PocketID if it exposes Prometheus metrics.
