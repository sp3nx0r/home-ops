---
name: oidc-gated-internal-route
description: Puts an auth-less web UI on the home-ops envoy-internal gateway behind Pocket ID OIDC in one PR that works on first reconcile. Covers native-OIDC vs gateway SecurityPolicy, the human steps (registering the Pocket ID client, setting the client secret without it entering chat, the browser login test), a standalone HTTPRoute, a SecurityPolicy with unique cookie names, gateway ingress in the backend CNP, and post-reconcile Accepted checks. Use when exposing a dashboard or admin UI internally (Hubble UI, Prometheus, Alertmanager, Thanos, Kopia style) or adding login to an app that has none.
---

# OIDC-gated internal route

## Mission

Ship a sensitive UI behind Pocket ID with no placeholder credentials in the merged PR, no client secret in chat, and no default-deny surprises.

## Human steps at a glance

The agent cannot do these. Pocket ID has no GitOps-managed clients, and the agent must never see the client secret. Ask for each one explicitly and wait.

| When                                | **[HUMAN]** action                                                           | What comes back to the agent                          |
| ----------------------------------- | ---------------------------------------------------------------------------- | ----------------------------------------------------- |
| Before any files (step 2)           | Create the OIDC client in the Pocket ID admin UI                             | Client ID and allowed group name. **Not the secret.** |
| Before commit (step 6)              | Run one `sops set --value-stdin` command in the worktree to store the secret | "done"                                                |
| After merge and reconcile (step 10) | Load the URL in a browser and log in                                         | "works" or what they saw                              |

## Prerequisites

- Live SecurityPolicies to copy (`kubectl get securitypolicy -A`): `kube-system/hubble-ui-oidc`, `o11y/prometheus-oidc`, `o11y/alertmanager-oidc`, `o11y/thanos-oidc`, `volsync-system/kopia-oidc`. Best template: `kubernetes/apps/volsync-system/kopia/app/securitypolicy.yaml`. Standalone route example: `kubernetes/apps/kube-system/cilium/app/httproute.yaml`.
- Background: `docs/completed/pocket-id-oidc.md` ("Protecting Apps with OIDC"). **Parts are stale:** troubleshooting says `-n envoy-gateway-system`, but the controller is `deploy/envoy-gateway` in `network`. The "Apps Currently Using OIDC" table lists qui as a SecurityPolicy app (it uses native `QUI__OIDC_*`) and is missing the five policies above.
- Envoy → Pocket ID discovery egress already exists in `network/envoy-gateway/app/ciliumnetworkpolicy.yaml` (`:10443`).

## Workflow

1. **Pick the pattern.** If the app has native OIDC (Grafana `generic_oauth`, qui `QUI__OIDC_*`), use that and skip the SecurityPolicy. The callback path is then app-specific (qui: `/api/auth/oidc/callback`), so take it from the app's docs for step 2. Gateway SecurityPolicy is for UIs with no auth of their own.

2. **[HUMAN] Register the Pocket ID client before writing files.** Send one message with exactly what to enter, using the **real** domain (the user types into a UI, so `${SECRET_DOMAIN}` means nothing there). Then stop and wait.

    > **Action needed in Pocket ID** (`https://id.<domain>` → Administration → OIDC Clients → Add):
    >
    > - Name: `<App>`
    > - Callback URL: `https://<host>.<domain>/oauth2/callback`
    > - Logout callback URL: `https://<host>.<domain>/logout`
    > - Public client: **off** (Envoy authenticates with the secret)
    > - Allowed user groups: which group(s) should get in? With none set, any Pocket ID user can log in.
    >
    > Reply with the **client ID** and the **group name**. **Don't paste the client secret here.** Keep the page open, or regenerate the secret later. I'll give you a command to store it encrypted.

    If the user wants the PR first, continue with a placeholder secret (step 6) and open the PR as a **draft**. Put the client steps at the top of the body and set the title to `… (blocked: Pocket ID client)`.

3. **Route.** Use the chart's `route:` value if it has one (app-template). Otherwise add `app/httproute.yaml`:

    ```yaml
    ---
    # yaml-language-server: $schema=https://k8s-schemas.home-operations.com/gateway.networking.k8s.io/httproute_v1.json
    apiVersion: gateway.networking.k8s.io/v1
    kind: HTTPRoute
    metadata:
        name: <app>
    spec:
        parentRefs:
            - name: envoy-internal
              namespace: network
              sectionName: https
        hostnames: ["<host>.${SECRET_DOMAIN}"]
        rules:
            - backendRefs:
                  - name: <service>
                    port: <service-port>
    ```

    Take the Service name and port from the render, not memory. Charts like Cilium's `hubble.ui.ingress` create a legacy Ingress; don't use it. Internal routes sync to UniFi DNS automatically.

4. **SecurityPolicy** (`app/securitypolicy.yaml`), copied from kopia. Change:
    - `metadata.name: <app>-oidc`; `targetRefs[0].name` = the **exact** HTTPRoute name (chart-generated names differ; check `kustomize build` output).
    - `clientID` (from step 2; not secret), `clientSecret.name: <app>-oidc-secret`, `redirectURL` (must match the Pocket ID callback exactly).
    - `cookieNames.idToken`/`accessToken`: `<app>-id-token`/`<app>-access-token`. These **must be unique**, because every app shares `cookieDomain: "${SECRET_DOMAIN}"`.

5. **Secret skeleton** (`app/oidc-secret.sops.yaml`, same namespace as the policy). Write it with an inert placeholder and encrypt immediately:

    ```yaml
    ---
    apiVersion: v1
    kind: Secret
    metadata:
        name: <app>-oidc-secret
    stringData:
        client-secret: "REPLACE_ME"
    ```

    ```sh
    sops --encrypt --in-place kubernetes/apps/<ns>/<app>/app/oidc-secret.sops.yaml
    ```

6. **[HUMAN] Store the client secret.** Send this, with the worktree path filled in, and wait for "done". The secret goes from Pocket ID to SOPS through a hidden prompt on their terminal; it never enters chat, shell history or the process list.

    > **Action needed in your terminal:** paste the Pocket ID client secret at the silent prompt.
    >
    > ```sh
    > cd <worktree> && read -rs s && printf '%s' "$s" | jq -Rs . \
    >   | sops set --value-stdin kubernetes/apps/<ns>/<app>/app/oidc-secret.sops.yaml '["stringData"]["client-secret"]'; unset s
    > ```

    Then verify **without printing the value**:

    ```sh
    f=kubernetes/apps/<ns>/<app>/app/oidc-secret.sops.yaml
    sops -d "$f" | yq '.stringData | keys'                                   # [client-secret]
    sops -d "$f" | yq '.stringData."client-secret" != "REPLACE_ME"'          # true
    ```

    If the user did paste the secret in chat, don't repeat it; use the same `sops set --value-stdin` path, and suggest they regenerate it in Pocket ID afterwards.

7. **Wire it**: add the route, policy and secret files to `app/kustomization.yaml`. Confirm `ks.yaml` has `postBuild.substituteFrom: cluster-secrets`, or `${SECRET_DOMAIN}` stays literal.

8. **Backend CNP** (outside `kube-system`): ingress `fromEndpoints` `io.kubernetes.pod.namespace: network` + `gateway.envoyproxy.io/owning-gateway-name: envoy-internal` on the **container** port. Without it, login succeeds and the request then 503s or times out. `kube-system` is outside the floor, so Hubble UI needs no CNP. See `cilium-cnp-authoring`.

9. **Validate and commit**:

    ```sh
    kustomize build kubernetes/apps/<ns>/<app>/app | rg 'kind: (HTTPRoute|SecurityPolicy|Secret)'
    for f in httproute securitypolicy; do                                     # CRD schema check
      SECRET_DOMAIN=example.com envsubst '${SECRET_DOMAIN}' < kubernetes/apps/<ns>/<app>/app/$f.yaml \
        | kubectl apply --dry-run=server -n <ns> -f -
    done
    ```

    Substitute a dummy domain first: HTTPRoute `hostnames` rejects a literal `${SECRET_DOMAIN}`. Commit only your paths (`home-ops-worktree-pr`). Open the PR as ready only if step 6 is done; otherwise draft, as in step 2.

10. **After merge and reconcile** (`flux-rollout-watch`):

    ```sh
    kubectl -n <ns> get httproute <app> -o jsonpath='{.status.parents[*].conditions[?(@.type=="Accepted")].status}'
    kubectl -n <ns> get securitypolicy <app>-oidc -o jsonpath='{.status.ancestors[*].conditions[*].message}'   # "Policy has been accepted."
    kubectl -n network logs deploy/envoy-gateway --tail=200 | rg -i <app>                                       # if not accepted
    ```

    **[HUMAN] Browser test.** Ask the user to load `https://<host>.<domain>` in a private window. It should bounce through `id.<domain>` and back to the app. Map the reported failure:
    - Pocket ID "invalid callback URL": the callback in Pocket ID doesn't match `redirectURL` exactly.
    - Pocket ID "not allowed": the user isn't in the client's allowed group.
    - Back at the app with 401 or a login loop: wrong client secret or client ID. Redo step 6 (`sops set` again) rather than editing ciphertext.
    - 503 or timeout after login: backend CNP missing gateway ingress (step 8). Check `hubble-drop-triage`.

11. **Docs**: add the app to the OIDC table in `docs/completed/pocket-id-oidc.md` in the same PR (and fix the stale lines if you touch the file). Don't push doc follow-ups straight to `main` without asking.

## Gotchas & Edge Cases

- If several SecurityPolicies go `Accepted=False` together after a network change, envoy-gateway may not have re-translated. See `cilium-cnp-authoring` (restart `deploy/envoy-gateway`, with permission).
- Editing an encrypted file: use `sops set` or `sops <file>`. Never hand-edit ciphertext.
- `sops set` takes a **JSON-encoded** value; `jq -Rs .` does the quoting. A raw string fails to parse.
- Never print the decrypted secret to check it; compare against the placeholder or check `length`.
- Placeholders cost a full extra round trip last time (re-encrypt, second commit, doc and PR-body rewrite). Do step 2 first whenever the user is available.
- An `envoy-external` route needs a UniFi CNAME in `kubernetes/apps/network/unifi-dns/app/dnsendpoint.yaml` for Gatus (AGENTS.md); internal routes don't.
- The gateway's `allowedRoutes: All` permits routes from any namespace, so a route in `kube-system` works.

## Output Template

```text
PR: [#<n>](https://github.com/sp3nx0r/home-ops/pull/<n>) (draft if blocked)
Host: <host>.${SECRET_DOMAIN} (envoy-internal, Pocket ID)

Human steps:
  [x| ] Pocket ID client registered (callback …/oauth2/callback, logout …/logout, group: <g>)
  [x| ] Client secret stored via sops set --value-stdin (verified ≠ placeholder)
  [x| ] Browser login confirmed after reconcile

Files: app/{httproute,securitypolicy,oidc-secret.sops,kustomization,ciliumnetworkpolicy}.yaml, docs/completed/pocket-id-oidc.md
Validated: kustomize ✓ · CRD dry-run ✓ · lefthook ✓
Post-reconcile: route Accepted · policy accepted
```
