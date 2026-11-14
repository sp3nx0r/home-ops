# OIDC least privilege (Pocket ID → Kubernetes)

Status: **proposed** (draft PR). Addresses finding **S2** ("IdP ⇒ cluster-admin")
and the break-glass half of **S5** from `docs/sre-and-security-evaluation.md`.

## Summary

Before this change, anyone who could get a Pocket ID ID token carrying the `k8s_admins`
group got `cluster-admin`. That covers three cases: an attacker with a stolen passkey
or session, a Pocket ID admin editing group membership, or a stolen Pocket ID signing
key. The change:

1. Rebinds `oidc:k8s_admins` from `cluster-admin` to a curated ClusterRole
   **`homelab-operator`**: `view` plus a few writes that can't escalate.
2. Leaves `oidc:k8s_viewers` → `view` unchanged.
3. Adds **no** OIDC break-glass group. `cluster-admin` stays reachable only
   through the talosctl-generated client-cert kubeconfig, which does not
   depend on Pocket ID.
4. Tightens the kube-apiserver `KubeAuthenticationConfig` (Talos) with CEL
   claim/user validation, a group allowlist, and a fix for anonymous auth.
5. Adds a break-glass runbook: `docs/runbooks/runbook-break-glass-access.md`.

## Threat model

| Actor / event                                                             | Before                                     | After                                                                                                                                             |
| ------------------------------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Stolen Headlamp session / refresh token (30d default)                     | cluster-admin                              | `homelab-operator` (read + pod delete + scale)                                                                                                    |
| Pocket ID admin adds a user to `k8s_admins`                               | cluster-admin                              | `homelab-operator`                                                                                                                                |
| Pocket ID compromised (DB / signing key) → forge any claims               | cluster-admin                              | `homelab-operator`. A forged `system:*` group is filtered out by the groups expression and the `oidc:` prefix, and non-`k8s_*` groups are dropped |
| New RoleBinding to some other Pocket ID group (e.g. `oidc:grafana_admin`) | would take effect                          | groups not starting with `k8s_` never reach RBAC                                                                                                  |
| JWT access token / client_credentials token for the Headlamp client       | accepted if it had `email`                 | rejected (`type == "id-token"` and `email_verified` required)                                                                                     |
| Pocket ID down                                                            | Headlamp locked; kubectl unaffected (cert) | same: break-glass is the cert kubeconfig (runbook)                                                                                                |

What is **not** protected: whoever holds `oidc:k8s_admins` can still read
everything `view` exposes (ConfigMaps, pod specs, CRs) and cause availability
damage (delete pods, scale to 0). Flux reverts replica drift for
Kustomization-managed objects on the next reconcile. The cert kubeconfig
(`system:masters`) cannot be revoked short of rotating the cluster CA, so the
workstation holding it is the real crown jewel.

## Audit evidence (read-only, Loki `{source="kube-audit"}`)

The audit stream starts on **2026-09-25 18:04Z**: about 5 days of data, well
short of the 30d retention. Queried 2026-09-30 through a `loki-0` port-forward.

- **One OIDC identity:** `oidc:spencer@securimancy.com`, **660 requests**, all
  `userAgent=Headlamp`, source `192.168.5.181` (the owner's workstation, via
  the Headlamp pod).
- **Groups in the token:** `oidc:k8s_admins`, `oidc:grafana_admin`,
  `oidc:chat_user`, `oidc:qui_admin`. Only the first one is used by RBAC.
- **Verbs:** `watch` 336, `list` 317, `get` 7. **Zero writes, zero
  subresources** (no exec/log/portforward).
- **Top resources:** nodes (150 list), namespaces, pods, jobs, CRDs, and Flux
  objects (helmreleases, kustomizations, ocirepositories, gitrepositories,
  receivers, providers, alerts).
- **Namespaces:** mostly cluster-scoped. Namespaced ones were `flux-system` 66,
  `o11y` 21, `media` 8, and ≤3 each in `network`, `kube-system`, `download`.
- **One Secret access:** `watch` on `media/autobrr-volsync-secret` (Headlamp
  detail page). This is the one observed request the new role will deny.
- **Response codes:** 101/200 normal, 36× 404, 9× 429 (apiserver storage
  re-init).
- **Day-to-day kubectl:** user `admin` (groups `system:masters`), X.509
  `CN=admin,O=system:masters`, cert expires 2027-04-25. It is used from
  `192.168.5.181` via `kubectl` (≈3.4k requests), `flux`, `helm`, and `kubens`.
  This is the talosctl-generated kubeconfig, and all real changes go through it
  or through Git.
- **Anonymous:** only `kube-probe` hitting `/readyz` and `/livez`. The only
  other anonymous requests were two 403s from Headlamp after a token expired.

Conclusion: the OIDC path is used purely for browsing. Dropping it to
`view`-plus has no observed functional cost apart from the one Secret view.

Existing bindings with OIDC subjects (live):

| Binding                 | Role            | Subject            |
| ----------------------- | --------------- | ------------------ |
| `headlamp-oidc-admins`  | `cluster-admin` | `oidc:k8s_admins`  |
| `headlamp-oidc-viewers` | `view`          | `oidc:k8s_viewers` |

## Research

### Kubernetes structured authentication

- `AuthenticationConfiguration` (`StructuredAuthenticationConfiguration`)
  reached GA in **v1.34** ([feature gate][fg-sac]). The cluster runs v1.37.1.
- Supported fields ([docs][k8s-authn]):
    - `claimValidationRules[].expression`: CEL over `claims`.
    - `claimMappings.{username,groups,uid}.expression`: CEL. Mutually exclusive
      with `claim`/`prefix`, so the prefix has to be part of the expression.
    - `userValidationRules[].expression`: CEL over the final `user`.
    - `anonymous.{enabled,conditions}`.
- When `username.claim: email` is set, the apiserver adds an implicit
  `claims.?email_verified.orValue(true) == true` check. A token _without_
  `email_verified` still passes, so we add a strict rule.
- CEL gotcha, caught by an offline test: `claims.?groups.orValue([])` is typed
  `any` and can't be iterated with `filter`/`map`. It has to be wrapped as
  `dyn(...)`.

### Talos 1.14 `KubeAuthenticationConfig`

- `configuration` is `Unstructured` and passed through literally ([Talos
  v1.14 reference][talos-authn]). The controller validates it against the typed
  `apiserver.config.k8s.io/v1beta1` schema and writes it to
  `/system/config/kubernetes/kube-apiserver/authentication-config.yaml`
  (`internal/app/machined/pkg/controllers/k8s/control_plane.go`). So CEL
  rules, expressions, and `anonymous` are all supported. `--oidc-*`
  extraArgs are rejected.
- The field is `merge:"replace"`
  (`pkg/machinery/config/types/k8s/authentication.go`), so a patch **replaces
  the default document**. Talos's default limits anonymous auth to
  `/livez`, `/readyz`, and `/healthz`. The live rendered config (`talosctl get
authenticationconfigs`) has **no `anonymous` block**, and anonymous
  `GET /version` returns 200. The apiserver has fallen back to
  unconditional anonymous auth. RBAC still limits `system:anonymous` to
  `public-info-viewer` (so `/api` → 403), but this is a silent regression, so
  the patch restates the default.

### Pocket ID (v2.16.0 source)

- **Tokens:** ID token lifetime is 1h (fosite default; `IDTokenLifespan` is
  unset in `backend/internal/oidc/provider.go`). The access token default is 60
  min (`DefaultAccessTokenDurationMinutes`). The refresh token default is
  **30 days** (`DefaultRefreshTokenDurationMinutes`), adjustable per client.
  Refresh re-checks that the user is enabled and still in an allowed group
  (`ValidateUserAccess`). Already-issued ID tokens stay valid until `exp`,
  because the apiserver does not check revocation.
- **Claims:** `email` and `email_verified` are only emitted together, and only
  when the user has an email (`oidc/claims_service.go`). `email_verified`
  reflects the user's DB flag. `groups` is the list of group **names**. ID
  tokens carry `type: "id-token"`. `email`, `email_verified`, `groups`, `sub`,
  `type`, etc. are **reserved** and cannot be overridden by custom claims
  (`service/custom_claim_service.go`).
- **Grants:** `client_credentials` and device-code grants are enabled
  instance-wide (discovery doc). A `client_credentials` token has no user and
  no `email`, so the apiserver rejects it. The `type` rule also rejects JWT
  access tokens generally.
- **Group membership** is editable by any Pocket ID **admin** (UI/API). Per-client
  **allowed user groups** (`IsUserGroupAllowedToAuthorize`) can restrict who
  may log in to Headlamp at all.
- **Passkey-only** login is the design; users sign in with WebAuthn passkeys or
  admin-issued one-time access links (`one-time-access-token` CLI). The
  one-time link is effectively a password-reset path, so Pocket ID admin
  accounts are the trust root.
- **Key rotation:** `pocket-id key-rotate` generates a new signing key. The
  apiserver caches the JWKS and may keep accepting old-key tokens until it
  refreshes or restarts, so rotation is not an instant cutoff.

### Headlamp

- Forwards the user's **ID token** (`config.oidc.useAccessToken: false`,
  chart 0.45.0 default) as the bearer to the apiserver, so every request is
  authorised as the OIDC user.
- Read views need `get/list/watch` on the resources shown (covered by `view`
  and the repo's `custom:aggregate-*-view` roles, including Flux, Cilium,
  cert-manager, Kubescape, and metrics). Logs need `pods/log` get (in `view`).
- Buttons that need more than `view`:
    - **Delete pod:** granted.
    - **Scale:** granted, via the `scale` subresource.
    - **Restart:** `patch` on the workload. Not granted; delete the pods
      instead.
    - **Edit YAML:** not granted.
    - **Terminal/exec** and **port-forward:** not granted.
    - **Secrets** pages: not granted.
    - **Flux plugin Sync / Suspend:** `patch` on Flux objects. Not granted.
    - **Node cordon/drain:** `patch nodes` plus eviction. Not granted; drain
      through the cert kubeconfig or `talosctl`.

### RBAC escalation vectors ([k8s RBAC good practices][rbac-gp])

Each of these is equivalent to cluster-admin in this cluster, so all are
excluded:

| Permission                                                                   | Why it escalates                                                                                                                                                                                                                                            |
| ---------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `secrets` get/list/watch                                                     | SA tokens, SOPS-decrypted app creds, the Flux deploy key, and `talos.dev` ServiceAccount talosconfigs (`os:admin` in `system-upgrade`). `list` returns values.                                                                                              |
| `pods/exec`, `pods/attach`, `pods/portforward`                               | Shell in e.g. `kustomize-controller` → its cluster-admin SA token. Port-forward reaches unauthenticated in-cluster admin APIs.                                                                                                                              |
| `nodes/proxy`                                                                | Kubelet API → exec in any pod (including via `get` + websocket).                                                                                                                                                                                            |
| `serviceaccounts/token` create, `impersonate`                                | Mint or assume any identity.                                                                                                                                                                                                                                |
| `create`/`patch` pods, deployments, daemonsets, statefulsets, jobs, cronjobs | A pod template can mount any SA in its namespace, run privileged, or use hostPath. `kubectl create job --from=cronjob` is plain `create jobs`, and so is `rollout restart`'s `patch`. RBAC cannot restrict fields.                                          |
| RBAC writes, `escalate`, `bind`                                              | Direct.                                                                                                                                                                                                                                                     |
| Admission webhooks / ValidatingAdmissionPolicies, CRDs                       | Intercept or rewrite every request; break controllers.                                                                                                                                                                                                      |
| CSR approve (`certificatesigningrequests/approval`, `signers` approve)       | Issue a `system:masters` client cert.                                                                                                                                                                                                                       |
| `cilium.io` policy writes                                                    | Remove the default-deny floor (e.g. `system-upgrade` → Talos API).                                                                                                                                                                                          |
| Flux `Kustomization`/`HelmRelease`/`*Repository` patch                       | `spec.patches`, `spec.path`, `spec.values`, `sourceRef`, `serviceAccountName`, and a repo URL are applied by controllers running as cluster-admin. An inline patch on the `headlamp` Kustomization could rewrite this very binding back to `cluster-admin`. |
| `talos.dev` ServiceAccount create, `tuppr` upgrade CRs                       | Talos API access / node upgrades.                                                                                                                                                                                                                           |

**Flux suspend/reconcile via OIDC:** RBAC can't limit a `patch` to
`spec.suspend` or the `reconcile.fluxcd.io/requestedAt` annotation, so this is
**rejected**. It could be done safely with a `ValidatingAdmissionPolicy` that,
for `oidc:*` users, requires `object.spec` to equal `oldObject.spec` apart from
`suspend`, and allows annotation changes only under `reconcile.fluxcd.io/`.
The audit data shows no Flux writes via Headlamp, so that is left as a future
option rather than more admission logic to trust.

## Role design: `homelab-operator`

`kubernetes/apps/kube-system/cluster-rbac/app/homelab-operator.yaml`, an
aggregated ClusterRole:

- selector `rbac.authorization.k8s.io/aggregate-to-view: "true"` (identical to
  what `view` aggregates, including the repo's `custom:aggregate-*-view` roles)
- selector `securimancy.com/aggregate-to-homelab-operator: "true"`, which
  selects `custom:aggregate-homelab-operator-day2`

Bound by `headlamp-oidc-operators` (`o11y/headlamp/app/rbac.yaml`). `roleRef`
is immutable, so the binding gets a new name, and Flux prunes the old
`headlamp-oidc-admins`.

| Allow                                                                                           | Deny (explicitly absent)                                                   |
| ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| everything in `view` (get/list/watch on workloads, config, CRs, nodes, PVs, CRDs, RBAC objects) | `secrets` (any verb)                                                       |
| `pods/log` get (via `view`)                                                                     | `pods/exec`, `pods/attach`, `pods/portforward`, `pods/ephemeralcontainers` |
| `pods` **delete** (restart via controller)                                                      | `nodes/proxy`, `nodes` patch (cordon)                                      |
| `pods/eviction` **create** (PDB-respecting restart)                                             | `serviceaccounts/token`, `impersonate`                                     |
| `deployments/scale`, `statefulsets/scale` get/update/patch                                      | create/patch/update on any workload, Job, CronJob, ConfigMap, Service      |
| `jobs` **delete** (clear failed jobs)                                                           | RBAC writes, `escalate`, `bind`                                            |
|                                                                                                 | webhooks, VAPs, CRDs, CSR approval, Cilium policies                        |
|                                                                                                 | Flux objects (any write), `talos.dev`, `tuppr` writes                      |

**Exec: option, not default.** Exec anywhere is cluster-admin (see table). If
you want it, add a _namespaced_ `RoleBinding` granting `pods/exec` in low-risk
namespaces only (e.g. `media`, `download`). Every such use fires
`KubernetesInteractivePodAccess` from PR #554. Even then, exec exposes every
Secret mounted in that namespace. Recommendation: keep exec off and use the
cert kubeconfig.

**Validation performed:**

- `kubectl apply --dry-run=server` on the new ClusterRoles and bindings: ok.
- `kubeconform -strict`: ok.
- A script took the effective rule set (live `view` plus the day-2 rules) and
  checked 43 escalation permissions from the table above. **0 violations.**
  The only non-read grants are `pods` delete, `pods/eviction` create,
  `{deployments,statefulsets}/scale` update/patch, and `jobs` delete.

## Break-glass decision

**No `oidc:k8s_breakglass` → `cluster-admin` group.** Any OIDC-mapped
cluster-admin group puts S2 straight back. It would be exactly as strong as the
weakest Pocket ID admin account or the signing key, and would only help when
Pocket ID is up, which is not when break-glass is needed.

Instead, break-glass is the **talosctl-generated admin kubeconfig**
(`CN=admin,O=system:masters`):

- Minted over the Talos API (mTLS, `os:admin` talosconfig), independently of
  Pocket ID, the apiserver's JWT authenticator, and RBAC.
- Already the day-to-day kubectl identity (audit evidence), so it is
  exercised constantly and won't have rotted when it's needed.
- Recoverable from Git: `secrets.sops.yaml` + `age.key` → `just talos
talosconfig` → `talosctl kubeconfig`.

Risks accepted: client certs can't be revoked (only CA rotation), and the
current cert expires 2027-04-25 (talosconfig 2027-08-30). Keep `age.key` backed
up offline, since it is the root of the whole chain.

## Talos authn tightening (`talos/control-plane/00-cluster.yaml`)

A small, isolated diff to the `KubeAuthenticationConfig` document only:

- `anonymous.enabled: true` limited to `/livez`, `/readyz`, `/healthz`. This
  restores the Talos default and fixes unconditional anonymous auth. kubelet
  probes use only `/livez` and `/readyz`.
- `claimValidationRules`:
    - `claims.?email_verified.orValue(false) == true`: strict, whereas the
      built-in check passes when the claim is absent.
    - `claims.?type.orValue("") == "id-token"`: Pocket ID ID tokens only.
- `claimMappings.groups.expression`:
  `dyn(claims.?groups.orValue([])).filter(g, g.startsWith("k8s_")).map(g, "oidc:" + g)`.
  This keeps the same `oidc:` prefix and drops non-k8s groups.
- `userValidationRules`: username/groups must not start with `system:`. Belt
  and braces on top of the prefixes, in case someone later edits the mapping.

Username stays `email` with the `oidc:` prefix, so the PR #554 detections keep
matching. `sub` would be immutable, while email is admin-editable, but no RBAC
binds to individual users, so the change isn't worth breaking the audit
queries.

**Validation performed:**

- `topf render` → `talosctl validate --mode metal --strict` for all 3 nodes: valid.
- `topf apply --dry-run` (miirym): the diff touches only
  `KubeAuthenticationConfig`, and no reboot is required.
- Offline Go harness with `k8s.io/apiserver@v0.37.1` running
  `validation.ValidateAuthenticationConfiguration` (compiles the CEL) plus the
  real `oidc.New` authenticator against RS256 tokens signed with a test key:

    | Token                                                  | Current config                            | New config                           |
    | ------------------------------------------------------ | ----------------------------------------- | ------------------------------------ |
    | Pocket ID ID token (verified, type=id-token, 4 groups) | accepted, 4 `oidc:*` groups               | accepted, **only `oidc:k8s_admins`** |
    | `email_verified: false`                                | rejected                                  | rejected                             |
    | `email_verified` absent                                | **accepted**                              | rejected                             |
    | no `type` / `type: access-token`                       | **accepted**                              | rejected                             |
    | `groups: [system:masters, k8s_viewers]`                | `oidc:system:masters`, `oidc:k8s_viewers` | `oidc:k8s_viewers`                   |
    | no `groups` claim                                      | accepted, no groups                       | accepted, no groups                  |
    | no `email` (client_credentials)                        | rejected                                  | rejected                             |
    | wrong `aud`                                            | rejected                                  | rejected                             |

## Interaction with PR #554 (Loki Sigma detections)

[PR #554](https://github.com/sp3nx0r/home-ops/pull/554) adds
`KubernetesWriteByOIDCUser`, `KubernetesRBACSecretOrWebhookWriteByOIDCUser`, and
`KubernetesSecretReadByOIDCUser`. No new rules are added here.

- After this change, the permitted day-2 writes (pod delete, scale, job delete)
  still fire `KubernetesWriteByOIDCUser` (warning). That is intended.
- RBAC/Secret/webhook writes by `oidc:*` now fail at authorization, so the
  critical rule only fires if the RBAC change is reverted.
- Rule descriptions in #554 say "the OIDC group is bound to cluster-admin".
  Reword them after both PRs merge.
- Possible follow-up (in #554's framework): alert on `oidc:*` requests with
  `responseStatus.code=403` for Secrets, exec, or RBAC. These are denied
  attempts, which is a probing signal once the role no longer allows them.

## Rollout

1. **RBAC (this PR, Flux).** Merge. `cluster-rbac` creates
   `homelab-operator` and `custom:aggregate-homelab-operator-day2`. `headlamp`
   creates `headlamp-oidc-operators` and prunes `headlamp-oidc-admins`. Both
   are instant and reversible with `git revert`. The two Kustomizations are
   independent: a binding to a not-yet-existing role grants nothing until the
   role lands, and no step grants more than before.
2. **Verify RBAC** (cert kubeconfig):

    ```bash
    kubectl get clusterrole homelab-operator -o jsonpath='{.rules}' | jq length  # aggregated, non-zero
    kubectl get clusterrolebinding headlamp-oidc-admins                          # NotFound
    kubectl auth can-i --list --as=oidc:probe@example.com --as-group=oidc:k8s_admins | rg -v 'get|list|watch'
    for r in secrets pods/exec pods/portforward nodes/proxy serviceaccounts/token; do
      kubectl auth can-i create "$r" -A --as=oidc:probe@example.com --as-group=oidc:k8s_admins
    done                                                                          # all "no"
    kubectl auth can-i get secrets -A --as=oidc:probe@example.com --as-group=oidc:k8s_admins          # no
    kubectl auth can-i patch kustomizations.kustomize.toolkit.fluxcd.io -A --as=oidc:probe@example.com --as-group=oidc:k8s_admins  # no
    kubectl auth can-i delete pods -n media --as=oidc:probe@example.com --as-group=oidc:k8s_admins    # yes
    kubectl auth can-i patch deployments/scale -n media --as=oidc:probe@example.com --as-group=oidc:k8s_admins  # yes
    ```

    Then log in to Headlamp: browsing, logs, and Flux views work, while Secrets,
    terminal, and Restart return 403.

3. **Talos authn patch, one node at a time, with `try`.** Run this after step 2
   is confirmed:

    ```bash
    just talos diff                                   # expect only KubeAuthenticationConfig
    just talos apply-node miirym try                  # auto-reverts after the try timeout (1m default)
    # within the window: log in to Headlamp (fresh session) and confirm it works;
    # curl -sk https://192.168.5.50:6443/version -> 401, /livez -> 200
    just talos apply-node miirym auto                 # make it permanent
    # repeat for palarandusk, aurinax
    ```

    Headlamp goes through the VIP, so it may hit a node that isn't patched yet.
    Pin the test with `curl` against the node IP using the ID token from
    Headlamp's browser session, or just re-check after all three nodes are done.
    If the new rules lock out Headlamp, the `try` revert (or re-applying without
    the patch) fixes it. `kubectl` with the cert kubeconfig is unaffected either
    way.

4. **Pocket ID UI hardening (manual, no Git):**
    - Headlamp OIDC client → **Allowed user groups**: `k8s_admins`,
      `k8s_viewers`.
    - Headlamp OIDC client → **refresh token lifetime** 30d → ~12–24h.
    - Keep exactly one Pocket ID admin account (S2 recommendation), and make
      sure every user's email is marked verified (otherwise the strict
      `email_verified` rule locks them out).
5. **After #554 merges:** reword its S2 descriptions (see above).

## Decisions

1. Exec/port-forward through OIDC: **none**. Use the talosctl admin
   kubeconfig for exec.
2. Keep the Pocket ID group name `k8s_admins`; no rename.
3. Headlamp PKCE: **enabled**. `config.oidc.usePKCE: true` makes the chart pass
   `-oidc-use-pkce=$(OIDC_USE_PKCE)`, and in `externalSecret` mode that env var
   comes from `headlamp-oidc`, so the Secret carries `OIDC_USE_PKCE: "true"`.
   Without the key Headlamp gets the literal `$(OIDC_USE_PKCE)` and fails to
   start.
4. Losing Secret views in Headlamp is accepted. Use the cert kubeconfig or the
   SOPS file in Git instead.

[fg-sac]: https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/
[k8s-authn]: https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-authentication-configuration
[talos-authn]: https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubeauthenticationconfig
[rbac-gp]: https://kubernetes.io/docs/concepts/security/rbac-good-practices/
