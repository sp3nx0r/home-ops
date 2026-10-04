---
name: upstream-helm-chart-onboarding
description: Onboards a vendor (non-app-template) Helm chart into home-ops as a Flux app that starts cleanly under PSA, the Cilium default-deny floor, SOPS and Renovate, using the rendered chart rather than its docs. Use when adding a third-party chart, evaluating one ("should we deploy X"), or migrating an app from app-template to a vendor chart.
---

# Upstream Helm chart onboarding

## Mission

Turn a vendor chart into a Flux app using facts from the rendered manifests rather than the docs, so nothing breaks on first reconcile and nothing needs a follow-up PR for secrets or policy.

## Prerequisites

- Work on a branch off `origin/main`. CI runs flux-local (`.github/workflows/flux-local.yaml`) on the PR.
- Reference apps: `kubernetes/apps/kubescape/` (full privileged example), `storage/garage` (HelmRepository + `valuesFrom`), `system-upgrade/tuppr` (ndots postRenderer, `ks.yaml` with a dependent Kustomization), `o11y/prometheus-adapter` (aggregated APIService CNP), `o11y/gatus` (toFQDNs).
- Related skills: `cilium-cnp-authoring` (policies), `renovate-tracking-and-pinning` (digests, custom managers), `flux-rollout-watch` (merge and rollout). Bootstrap Job and vendor restore details: [reference.md](reference.md).

## Workflow

### Research: render it, don't read it

1. **Chart source Flux will use**, not git HEAD:
    ```sh
    helm show chart oci://<registry>/<chart> --version <v>            # denied/404 → not OCI; use a HelmRepository
    curl -s <repo>/index.yaml | yq '.entries."<chart>"[:5][] | .version + " " + .created'
    helm pull <chart> --repo <url> --version <v> --untar -d /tmp/<chart>
    ```
    Kubescape 1.40.5 was tagged in git but missing from `index.yaml`; only flux-local caught it.
2. **Render with candidate values** for the cluster version:
    ```sh
    KV=$(kubectl version -o json | jq -r .serverVersion.gitVersion)
    helm template <rel> /tmp/<chart>/<chart> -n <ns> -f /tmp/values.yaml --kube-version "$KV" \
      --api-versions monitoring.coreos.com/v1 --api-versions gateway.networking.k8s.io/v1 > /tmp/out.yaml
    rg '^kind:' /tmp/out.yaml | sort | uniq -c
    ```
3. **PSA level** from the security contexts. hostPID, hostPath, extra caps or `spc_t` mean `privileged` (and an AGENTS.md namespace-table update):
    ```sh
    yq 'select(.kind=="DaemonSet" or .kind=="Deployment" or .kind=="StatefulSet") | {"n": .metadata.name, "hostPID": .spec.template.spec.hostPID,
      "hostNet": .spec.template.spec.hostNetwork, "sc": [.spec.template.spec.containers[].securityContext],
      "vols": [.spec.template.spec.volumes[]? | .name + ":" + (.hostPath.path // "other")]}' /tmp/out.yaml
    ```
    Node agents: run the preflight in `talos-config-change` [reference.md](../talos-config-change/reference.md#node-agent-preflight).
4. **CNP inputs** from the render: pod labels (`app.kubernetes.io/component` is usually the most precise), container and probe ports, APIService/webhook objects (ingress from `kube-apiserver`/`host`/`remote-node`), CronJob and hook pod labels. Draw the component call graph.
5. **RBAC**: cluster-wide `secrets` get/list, leftover create rights (DaemonSets), aggregation into `view`. Look for chart toggles that narrow them:
    ```sh
    yq 'select(.kind=="ClusterRole" or .kind=="Role") | {"n": .metadata.name, "agg": .metadata.labels, "rules": .rules}' /tmp/out.yaml | rg -n -B3 -A3 'secrets|"\*"|create|patch|escalate|bind|impersonate'
    ```
6. **Real egress hosts.** Follow redirects (`curl -sIL <url> | rg -i '^(HTTP|location)'`). Read the source at the **pinned image tag** for verification steps (Sigstore TUF, `tuf-repo-cdn.sigstore.dev`). Leave out hosts that only appear in testdata.
7. **Generated secrets**: `rg -n 'lookup|randAlphaNum|genSelfSignedCert' /tmp/<chart>/*/templates`. Pin anything that encrypts data at rest (e.g. Harbor `secretKey`) from SOPS. Short-lived token certs can stay generated.
8. **Prior art**: `gh search code "<chart>" --filename helmrelease.yaml --json repository,path`. Comments in other repos record capability gotchas. Check live collisions: `kubectl get apiservices`, `kubectl get crd | rg -i <x>`.
9. For an evaluation request, stop here and return the Output Template's research table and questions.

### Implement

10. **Layout**: `kubernetes/apps/<ns>/{namespace.yaml,kustomization.yaml}` (PSA label; include `../../components/sops`; Flux discovers new namespace dirs automatically) and `<app>/ks.yaml`, `<app>/app/{ocirepository|helmrepository,helmrelease,ciliumnetworkpolicy,kustomization}.yaml`. Use a `HelmRepository` only when there's no OCI chart, and say why in one line.
11. **Pin images to the index digest** for the tags the chosen chart version ships:
    ```sh
    raw=$(skopeo inspect --raw docker://<img>:<tag>); echo "sha256:$(printf '%s' "$raw" | sha256sum | cut -d' ' -f1) $(echo "$raw" | jq -r .mediaType)"
    rg 'image: ' /tmp/out.yaml | rg -v sha256      # must be empty
    ```
12. **Secrets via `valuesFrom`**, never in the HR spec:
    ```yaml
    valuesFrom:
        - kind: Secret
          name: <app>-values
          valuesKey: <key>
          targetPath: <path.in.values>
          literal: true # keep JSON/bcrypt verbatim; without it strvals splits on commas
    ```
    Generate values in a script (`openssl rand -hex 24`, `htpasswd` via `docker run --rm httpd:2.4-alpine htpasswd -nbB`), pipe them through `yq -n ... strenv(...)` into `secret.sops.yaml`, and `sops --encrypt --in-place` immediately. Plaintext never goes through the Write tool or the transcript.
13. **One CNP per component.** DNS egress in each; internet (`toFQDNs` or the AGENTS.md `toCIDRSet`) only where needed; Garage egress only on the S3 pod; DB/Redis ingress-only; Prometheus on the metrics port; in-cluster OIDC to Pocket ID via envoy-internal (copy from an existing OIDC client CNP).
14. **postRenderers** for what the chart can't set: `dnsConfig.options ndots: "1"` on every `toFQDNs` pod (regex targets like `name: a|b` work), and `honorLabels: true` on ServiceMonitors whose exporters emit their own `namespace` label.
15. **Bundled DB backup** (if the chart supports `existingClaim`): `pvc.yaml` named `${APP}` sized `${VOLSYNC_CAPACITY}` + the `components/volsync` component. **Postgres runs as UID 999** with 0700 PGDATA, so set `VOLSYNC_UID`/`VOLSYNC_GID` to 999. Leave caches unbacked. Document that snapshots are crash-consistent. `just volsync restore` only works for app-template; write manual restore steps ([reference.md](reference.md)).
16. **API-only settings** (projects, retention, GC): an idempotent bootstrap Job in a second Kustomization ([reference.md](reference.md)).
17. **Alerts**: verify metric names, labels **and label values** in upstream source at the deployed tag. Harbor's job failure status is `fail`, not `Error`, and its quota metrics have no `type` label. Aggregated APIServer: alert on `aggregator_unavailable_apiservice{name="..."}`, and add an `aggregate-to-view` role if the chart lacks one.
18. **Dashboards** vendored at a pinned commit (SHA in a kustomization comment). Scan them for `${...}` tokens that postBuild would rewrite.
19. **Renovate**: check `.renovaterc.json5` `customManagers`. A generic regex (the Headlamp plugins manager) can capture your new entry and look it up in the wrong datasource.
20. **Validate** before opening the PR:
    ```sh
    kustomize build kubernetes/apps/<ns> > /dev/null && kustomize build kubernetes/apps/<ns>/<app>/app > /dev/null
    ```
    The new namespace doesn't exist yet, so for a server dry-run, re-render with `-n` set to an existing namespace at the same PSA level (`default` for baseline, `kubescape` for privileged) and run `kubectl apply --dry-run=server -f`. That checks PSA admission and live CRD schemas.
    `cluster-secrets` always fails kubeconform (SOPS metadata); that's expected.

## Gotchas & Edge Cases

- **Privileges move between components across chart versions** (Kubescape folded host-scanner into node-agent). Disabling one capability can silently drop others. Render each tier and diff the workload lists.
- **Capability flags gate unrelated output** (Kubescape `continuousScan` also gates per-workload detail). Read the rendered capability ConfigMap.
- **A route-level BackendTrafficPolicy replaces the gateway one** rather than merging. Restate everything: for large uploads, retries off, compressor off, long `streamIdleTimeout`. Take the HTTPRoute name for `targetRefs` from the chart's route helper.
- **One global `containerSecurityContext`** in many vendor charts: global `readOnlyRootFilesystem` breaks images that write to root. Leave it off and say why.
- `envoy-internal` routes need no DNSEndpoint (UniFi external-dns syncs them); `envoy-external` hostnames need a UniFi CNAME for Gatus (AGENTS.md).
- Volsync movers need no NFS egress CNP (the kubelet mounts NFS).
- "dragonfly" in other home-ops repos is usually DragonflyDB (Redis), not the CNCF P2P registry.

## Output Template

```
Research: | component | kind | purpose | privileges/PSA | req→limit | API/network needs |
          Talos compatibility · overlap with existing tools · recommended tier + 1–2 alternatives (rendered) · numbered questions
Implementation: PR [#<n>](https://github.com/sp3nx0r/home-ops/pull/<n>) — chart <name> <ver> via <OCI|HelmRepository> (why)
  Capabilities on/off · PSA <level> · CNP egress hosts (why) · secrets <keys via valuesFrom> · backup <PVC, UID>
  Validation: kubeconform · dry-run · flux-local N/N · Renovate manager check
  Post-merge checks: HR Ready · APIService Available · drops in <ns> · first run via create job --from=cronjob/…
```
