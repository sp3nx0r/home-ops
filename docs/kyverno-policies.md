# Kyverno Policies

Operational notes for authoring Kyverno `ValidatingPolicy` resources and rolling them from Audit to Deny. These come from the `require-namespace-psa-enforce-label` rollout ([#524](https://github.com/sp3nx0r/home-ops/pull/524), [#563](https://github.com/sp3nx0r/home-ops/pull/563), [#564](https://github.com/sp3nx0r/home-ops/pull/564)).

## Layout

- Controllers: `kubernetes/apps/kyverno/kyverno/` (Flux Kustomization `kyverno/kyverno`)
- Policies: `kubernetes/apps/kyverno/policies/app/*.yaml`, `policies.kyverno.io/v1` `ValidatingPolicy` (Flux Kustomization `kyverno/kyverno-policies`)

| Policy                                | Actions         | Scope                                                                                                          |
| ------------------------------------- | --------------- | -------------------------------------------------------------------------------------------------------------- |
| `require-namespace-psa-enforce-label` | `[Deny, Audit]` | Namespaces, except `kube-system`, `kube-public`, `kube-node-lease`, `flux-system`, `kyverno`, `cilium-secrets` |
| `require-lb-no-nodeports`             | `[Deny, Audit]` | `type: LoadBalancer` Services in every namespace; requires `allocateLoadBalancerNodePorts: false`              |

## Rollout: Audit → Deny

1. Ship the policy with `validationActions: [Audit, Warn]` and `evaluation.background.enabled: true`. Without background evaluation, existing objects never get reports.
2. Read the findings (see [Reading reports](#reading-reports)) and cross-check them against both the live objects and git, so Flux won't reapply something the policy will reject. Helm releases with `createNamespace` bypass `namespace.yaml` and need checking separately.
3. Flip to `[Deny, Audit]`. Audit keeps the reports populated after enforcement.
4. After reconcile, wait a few seconds for the policy to compile into the webhook, then prove both directions with server-side dry runs:

    ```bash
    kubectl create ns kyverno-probe-test --dry-run=server   # expect: denied
    kubectl apply --dry-run=server -f - <<'EOF'              # expect: created (server dry run)
    apiVersion: v1
    kind: Namespace
    metadata:
      name: kyverno-probe-test
      labels:
        pod-security.kubernetes.io/enforce: baseline
    EOF
    ```

## Gotchas

- **`Deny` and `Warn` can't be combined** in `validationActions`; the admission API rejects it. Use `[Deny, Audit]`.
- **Before the flip, Audit + Warn only prints a client-side warning** on a dry run. "Warning, not blocked" is the expected pre-enforcement behaviour.
- **Exempted namespaces don't appear in reports.** Don't count their absence as a finding. Keep `kyverno` exempt so Kyverno can recover itself.
- **Re-verify stale rationale.** Comments and PR bodies like "deferred until X is labelled" go out of date; check the blocker still exists before trusting it.

## Reading reports

Results for cluster-scoped resources (Namespaces, ClusterRoles, …) land in `ClusterPolicyReport`, not `PolicyReport`. Querying only `policyreports -A` for a Namespace policy returns nothing.

```bash
# Cluster-scoped resources
kubectl get clusterpolicyreports -o json \
  | jq -r '.items[] | .scope.name as $n | .results[]? | select(.policy=="<policy>") | "\($n) \(.result)"' | sort | uniq -c

# Namespaced resources
kubectl get policyreports -A -o json \
  | jq -r '.items[] | .metadata.namespace as $ns | .results[]? | select(.policy=="<policy>" and .result!="pass") | "\($ns) \(.resources[0].name) \(.result) \(.message)"'
```

## Availability risk

The resource webhooks use `failurePolicy: Fail`, and `kyverno-admission-controller` runs one replica with no PDB. While it's down, every write that a policy matches is rejected, in Audit mode as well as Deny. Today that only covers Namespace create and update, plus create and update of `type: LoadBalancer` Services (other Services don't match the policy's `matchConditions`, so they never reach the webhook). Before adding policies that match Pods or other high-churn resources, either run 2–3 admission-controller replicas with a PDB, or set `failurePolicy: Ignore` on hygiene-only policies.
