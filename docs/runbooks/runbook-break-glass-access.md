# Runbook: Break-glass cluster access

## When to use this

- **Pocket ID is down.** Headlamp, Grafana, Prometheus, Alertmanager, Kopia,
  and qui logins all fail.
- **Pocket ID or an OIDC session is suspected compromised.** Examples: an
  unexpected `KubernetesWriteByOIDCUser` / `KubernetesSecretReadByOIDCUser`
  alert, a group-membership change you didn't make, or an unknown passkey.
- You need `cluster-admin` for anything the OIDC `homelab-operator` role
  deliberately can't do: Secrets, exec, RBAC, Flux object edits, or node drain.

OIDC users (`oidc:k8s_admins`) are **never** `cluster-admin`. The only
cluster-admin path is the talosctl-generated client-certificate kubeconfig
(`CN=admin,O=system:masters`). It depends on the Talos API, not Pocket ID. See
`docs/oidc-least-privilege-plan.md` for the reasoning.

## 1. Get a cluster-admin kubeconfig

The kubeconfig at `/opt/home-ops/kubeconfig` _is_ the break-glass credential
and is used day to day. Check that it works:

```bash
kubectl auth whoami            # Username: admin, Groups: [system:masters system:authenticated]
```

If it is missing, expired (current cert: 2027-04-25), or you're on another
machine, mint a new one from the Talos API:

```bash
cd /opt/home-ops
# talosconfig is gitignored; regenerate it from the SOPS secrets bundle if needed
# (requires age.key -> keep an offline copy)
[ -f talos/clusterconfig/talosconfig ] || just talos talosconfig > talos/clusterconfig/talosconfig
talosctl -n 192.168.5.50 kubeconfig ./kubeconfig --force --merge=false
kubectl auth whoami
```

If the VIP (`192.168.5.254`) is down, point at a node directly:
`kubectl --server https://192.168.5.50:6443 ...` (the node IPs are in the cert
SANs).

UIs without Pocket ID: `kubectl port-forward` bypasses the Envoy OIDC
`SecurityPolicy`:

```bash
kubectl -n o11y port-forward svc/kube-prometheus-stack-prometheus 9090:9090
kubectl -n o11y port-forward svc/grafana 3000:80        # Grafana local admin from its secret
```

## 2. Contain a suspected Pocket ID / OIDC compromise

Work from fastest to slowest. Steps 2a and 2b take effect immediately.

### 2a. Cut OIDC's Kubernetes access (instant)

```bash
kubectl delete clusterrolebinding headlamp-oidc-operators headlamp-oidc-viewers
flux suspend kustomization headlamp -n o11y   # stop Flux re-creating them
```

Already-issued ID tokens (1h lifetime) now authorise nothing.

### 2b. Stop Headlamp

```bash
flux suspend helmrelease headlamp -n o11y
kubectl -n o11y scale deploy/headlamp --replicas=0
```

### 2c. Revoke in Pocket ID (if the admin UI is trustworthy)

- **Users:** disable the affected user(s). Refresh then fails, because Pocket
  ID re-checks at issuance. Review group membership, especially `k8s_admins`,
  and the list of Pocket ID admins. Remove unknown passkeys.
- **OIDC client (Headlamp):** create a new client secret, delete the old one,
  and update `kubernetes/apps/o11y/headlamp/app/secret.sops.yaml`
  (`sops --encrypt --in-place`). If the client itself is suspect, recreate it
  and update the audience in `talos/control-plane/00-cluster.yaml`.
- **Signing key:** only if the Pocket ID database or pod was compromised.

    ```bash
    kubectl -n security exec deploy/pocket-id -- /app/pocket-id key-rotate --yes
    kubectl -n security rollout restart deploy/pocket-id
    ```

    The kube-apiserver caches the JWKS, so old-key tokens may still verify until
    it refreshes. Don't rely on rotation alone; do 2a and/or 2d.

### 2d. Remove the JWT authenticator entirely (Talos, minutes)

If Pocket ID can't be trusted at all, stop the apiserver trusting it. In
`talos/control-plane/00-cluster.yaml` set `KubeAuthenticationConfig`
`configuration.jwt: []` (keep the `anonymous` block), then:

```bash
just talos diff
just talos apply-node miirym auto && just talos apply-node palarandusk auto && just talos apply-node aurinax auto
```

Cert and service-account auth are unaffected.

### 2e. Investigate

```bash
kubectl -n o11y port-forward pod/loki-0 3122:3100
# every OIDC request in the last 24h, by verb/resource
curl -sG localhost:3122/loki/api/v1/query --data-urlencode \
  'query=sum by (verb, objectRef_resource, objectRef_namespace, responseStatus_code) (count_over_time({source="kube-audit"} | json | user_username=~"oidc:.*" [24h]))'
```

Look for denied (403) attempts on Secrets, exec, or RBAC. These are probing,
not normal Headlamp use.

## 3. Verify OIDC permissions (after any RBAC or authn change)

Impersonation needs the cert kubeconfig.

```bash
U=oidc:probe@example.com
kubectl auth can-i --list --as=$U --as-group=oidc:k8s_admins | rg -v '\[get list watch\]|\[get watch list\]'
# must all be "no"
for c in "get secrets" "create pods/exec" "create pods/portforward" "get nodes/proxy" \
         "create serviceaccounts/token" "impersonate users" "create clusterrolebindings" \
         "patch deployments" "create jobs" "patch kustomizations.kustomize.toolkit.fluxcd.io" \
         "patch helmreleases.helm.toolkit.fluxcd.io"; do
  printf '%-55s %s\n' "$c" "$(kubectl auth can-i $c -A --as=$U --as-group=oidc:k8s_admins)"
done
# expected "yes"
kubectl auth can-i delete pods -n media --as=$U --as-group=oidc:k8s_admins
kubectl auth can-i patch deployments/scale -n media --as=$U --as-group=oidc:k8s_admins
# viewers: read-only
kubectl auth can-i delete pods -n media --as=$U --as-group=oidc:k8s_viewers   # no
```

Confirm that the apiserver's authn config is the one in Git:

```bash
talosctl -n 192.168.5.50 get authenticationconfigs -o yaml
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.5.50:6443/version   # 401 (anonymous limited to health paths)
```

## 4. Restore

1. Fix or clean Pocket ID. Confirm the admin list, group membership, and
   passkeys.
2. Revert 2d if it was applied (re-add the `jwt` block, `just talos apply-node
… try` then `auto`).
3. `flux resume kustomization headlamp -n o11y` and `flux resume
helmrelease headlamp -n o11y`. This re-creates the OIDC bindings from Git.
4. Re-run section 3.
