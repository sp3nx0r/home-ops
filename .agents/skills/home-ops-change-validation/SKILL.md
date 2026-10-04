---
name: home-ops-change-validation
description: Runs the CI-equivalent and cluster-aware validation ladder for a change under kubernetes/ in home-ops before pushing — kustomize build, kubeconform diffed against origin/main, strict postBuild substitution with flux envsubst, helm template with real values and hand-applied postRenderers, flux-local test in Docker on throwaway git copies, and CRD/PSA/namespace server dry-runs. Use before committing any HelmRelease, Kustomization, CNP, PrometheusRule or component edit, when flux-local CI fails, or when deciding whether a kubeconform failure is new.
---

# home-ops: change validation ladder

## Mission

Prove a manifest change renders, validates and would be admitted, comparing against `origin/main` so only new failures count, without applying anything.

## Prerequisites

- A worktree with credentials wired (`home-ops-worktree-pr`). Server dry-runs need `kubectl`; everything else is offline.
- Tools via mise: `kustomize`, `kubeconform`, `helm`, `flux`, `yq`, `jq`, `sops`. Plus `docker` for flux-local.
- **Run every tool from the worktree** and pass temp-dir paths as arguments. `cd` into a temp dir leaves mise's scope; the shim then errors, and an empty result reads like "no new failures".
- CI reference: `.github/workflows/flux-local.yaml` (flux-local `v8.4.0`: `test --enable-helm --all-namespaces`, then `bash tests/volsync-cache-scrub.sh`, then a `diff` job).

## Workflow

Run the rungs that apply; stop and fix at the first new failure. Use one private temp dir (`V=$(mktemp -d)`), never shared `/tmp/kb-*` globs, which pick up other sessions' files.

1. **kustomize build** every directory you touched, on your branch and on `origin/main` (the namespace dir too, if you added a `ks.yaml`):
    ```sh
    V=$(mktemp -d); mkdir -p $V/pull $V/main/src
    git archive origin/main kubernetes | tar -x -C $V/main/src
    dirs="kubernetes/apps/<ns> kubernetes/apps/<ns>/<app>/app"
    for d in $dirs; do n=$(echo $d | tr / -)
      kustomize build "$d" > $V/pull/$n.yaml
      kustomize build "$V/main/src/$d" > $V/main/$n.yaml 2>/dev/null || : > $V/main/$n.yaml   # new dir: empty baseline
    done
    ```
2. **kubeconform, diffed against main:**
    ```sh
    KC='kubeconform -strict -ignore-missing-schemas -summary -schema-location default -schema-location https://k8s-schemas.home-operations.com/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
    for t in pull main; do $KC $V/$t/*.yaml > $V/kc-$t.raw 2>&1; tail -1 $V/kc-$t.raw   # must be a "Summary:" line
      rg 'invalid|error' $V/kc-$t.raw | sed "s#$V/$t/##; s/ - .*is invalid/ invalid/" | sort > $V/kc-$t.txt; done
    diff $V/kc-main.txt $V/kc-pull.txt && echo "no new kubeconform failures"
    ```
    Pre-existing failures on main: `sops:` metadata on Secrets, unsubstituted `${APP}`/`${VOLSYNC_CAPACITY}`, `${SECRET_DOMAIN}` failing hostname/`cookieDomain` patterns, and Volsync Kopia-fork fields (`spec.kopia`). Report "N new, M pre-existing".
3. **Substitution** (`postBuild.substitute`/`substituteFrom` in `ks.yaml`). Flux's envsubst (same library as `flux envsubst`):
    - Rewrites only braced `${VAR}`. An unset one becomes **empty, silently**. `${VAR:-default}` applies the default. `$${VAR}` escapes to a literal `${VAR}`.
    - Leaves alone: `$VAR`, `$(VAR)` (Kubernetes env refs, shell), `$1`, PromQL `{{ $labels.x }}` and `$value`. A braced `${1}` gets blanked; write `$1`.
    - Opt an object out with the `kustomize.toolkit.fluxcd.io/substitute: disabled` annotation (example: `o11y/gatus/app/kustomization.yaml`).
    - `substituteFrom` is per-Kustomization: `grafana/ks.yaml` has no `postBuild` (its dashboards keep `${DS_PROMETHEUS}`); `qui/ks.yaml` has `cluster-secrets`.
    - **Strict check**: feed the `ks.yaml` vars plus dummy values for the `cluster-secrets` keys (names only, never values); an unset `${VAR}` fails:
        ```sh
        app=kubernetes/apps/<ns>/<app>
        vars=$( { yq -r '.spec.postBuild.substitute // {} | to_entries[] | .key + "=" + (.value|tostring)' $app/ks.yaml
          yq -e '.spec.postBuild.substituteFrom[] | select(.name=="cluster-secrets")' $app/ks.yaml >/dev/null 2>&1 &&
            sops -d kubernetes/components/sops/cluster-secrets.sops.yaml | yq -r '.stringData | keys | .[] | . + "=dummy"'; } )
        kustomize build $app/app | env $(echo "$vars" | tr '\n' ' ') flux envsubst --strict > /dev/null && echo "envsubst: ok"
        ```
        Other `substituteFrom` Secrets (e.g. `alertmanager-secret`): add their keys the same way from the app's `secret.sops.yaml`.
4. **helm template with your real values** (charts, routes, securityContexts, RBAC):
    ```sh
    d=$(mktemp -d); helm pull oci://<registry>/<chart> --version <v> --untar -d $d
    yq '.spec.values' <hr.yaml> | sed 's/\${APP}/<app>/g; s/\${SECRET_DOMAIN}/example.com/g' > $d/values.yaml
    helm template <rel> $d/<chart> -n <ns> -f $d/values.yaml [-f $d/secret-values.yaml] \
      --api-versions gateway.networking.k8s.io/v1 --api-versions monitoring.coreos.com/v1 > $d/all.yaml
    ```
    - Put `valuesFrom` secret stand-ins in a values **file**. `--set` splits on commas and turns `y` into a boolean.
    - **Unknown keys are silently ignored.** Diff `helm template` with and without your new key; zero diff means the chart doesn't support it. Confirm against the chart's `values.yaml` or `values.schema.json` for the pinned version.
    - **postRenderers aren't applied by helm.** Apply them by hand and check the patch landed:
        ```sh
        yq '.spec.postRenderers[0].kustomize.patches' <hr.yaml> > $d/p.yaml
        printf 'resources: [all.yaml]\n' > $d/kustomization.yaml; yq -i ".patches = load(\"$d/p.yaml\")" $d/kustomization.yaml
        kustomize build $d > $d/post.yaml
        ```
        A kustomize target `name` is a regex: `vector-syslog` also matches `vector-syslog-headless`. Anchor it (`^vector-syslog$`).
5. **flux-local exactly as CI, on throwaway git copies.** flux-local can't follow a worktree's `.git` file, writes temp files into the tree, and resolves Kustomization paths from its working directory (`-w /r`; without it every Kustomization fails "is not a directory"):
    ```sh
    F=$(mktemp -d); mkdir -p $F/pull $F/main
    git ls-files -z kubernetes tests | xargs -0 tar -c | tar -x -C $F/pull   # also copy new untracked files
    git archive origin/main kubernetes tests | tar -x -C $F/main
    for t in pull main; do (cd $F/$t && git init -q && git add -A && git -c user.email=x@x -c user.name=x commit -qm s); done
    for t in pull main; do
      timeout 900 docker run --rm --user $(id -u):$(id -g) -e HOME=/tmp \
        -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0='*' \
        -v $F/$t:/r -w /r ghcr.io/allenporter/flux-local:v8.4.0 \
        test --enable-helm --all-namespaces --path kubernetes/flux/cluster > $F/fl-$t.log 2>&1
      tail -1 $F/fl-$t.log                                   # must read "N passed"; anything else is a broken run
      rg -o '^FAILED \S+' $F/fl-$t.log | sort -u > $F/fl-fail-$t; done
    diff $F/fl-fail-main $F/fl-fail-pull && echo "no new flux-local failures"
    ```
    About 2 minutes per run; start it in the background and do the other rungs meanwhile. To inspect rendered objects, run the same container with `build all --enable-helm kubernetes/flux/cluster`. Run `bash tests/volsync-cache-scrub.sh` when touching `components/volsync` or opting an app into Volsync.
6. **Server dry-runs** (admission + live CRD schemas; nothing is persisted):
    - CRD-backed objects (CNP, PrometheusRule, HelmRelease, SecurityPolicy, BackendTrafficPolicy): substitute, rename, and retarget to an existing namespace if yours doesn't exist yet:
        ```sh
        kustomize build <app>/app | yq 'select(.kind=="CiliumNetworkPolicy" or .kind=="SecurityPolicy") | .metadata.namespace="storage" | .metadata.name="dryrun-"+.metadata.name' \
          | sed 's/\${SECRET_DOMAIN}/example.com/g' | kubectl apply --dry-run=server -f -
        ```
    - **PSA**: only Pods are rejected, so dry-running a Deployment proves nothing. Convert pod templates into bare Pods in a namespace at the target level (`storage` is `baseline`, `system-upgrade` is `privileged`). Drop `serviceAccountName`, or admission fails on the missing SA before PSA runs:
        ```sh
        yq 'select(.kind=="Deployment" or .kind=="StatefulSet" or .kind=="DaemonSet") | {"apiVersion":"v1","kind":"Pod",
          "metadata":{"name":"psa-"+.metadata.name,"namespace":"storage"},"spec":(.spec.template.spec | del(.serviceAccountName))}' $d/post.yaml \
          | kubectl apply --dry-run=server -f -
        ```
        For StatefulSets with `volumeClaimTemplates`, add `{"name":"data","emptyDir":{}}` to `.spec.volumes` first. A PSA rejection reads `violates PodSecurity "baseline:latest": …`.
    - New namespace: dry-run the `namespace.yaml` too; the Kyverno `require-namespace-psa-enforce-label` policy rejects it if the label is missing.
7. **Live expressions**: parse-check any new PromQL/LogQL against the live stack (`o11y-history-forensics` helpers). Empty result ≠ wrong, but a parse error is.
8. Clean up only your own dirs: `rm -rf "$V" "$F" "$d"`; `git status --short` must show only your edits.

## Gotchas & Edge Cases

- **Empty output is not a pass.** Three ways a rung "passed" with nothing checked: kubeconform via a mise shim outside the repo, `docker run` with flags after the image name (passed to flux-local as arguments), flux-local without `-w /r`. Check each rung's summary line.
- **flux-local as root** fails on host-owned dirs; without `safe.directory` git refuses the repo. Use the `docker run` line above.
- **An empty `flux-local diff` isn't proof**: it misses postRenderers and can drop objects. Trust `build all` and the hand-applied rungs.
- **Helm versions differ**: mise pins helm `4.3.0` locally; the flux-local `v8.4.0` image ships `4.2.2`. If a chart breaks only in CI, check that first.
- **`kubectl apply --dry-run=server` on an existing object** runs a full update path. Webhooks may mutate it; field-manager conflicts are expected. Add `--server-side --force-conflicts --field-manager=dryrun-check` when you hit them.
- **`ks.yaml` `dependsOn` across namespaces** needs `namespace:` on the dependency (e.g. `volsync` in `volsync-system`). Flux app Kustomizations live in the app's namespace, not `flux-system`.
- **New CRD and first CR in the same PR**: flux-local and dry-run fail until the CRD exists. Split them, or note it as the expected failure.
- Python helpers: use `uv run --with <pkg>` or the repo `.venv`; don't `pip install` globally.

## Output Template

```text
Validation (<branch> vs origin/main <sha>):
- kustomize: ok (<dirs>)
- kubeconform: <n> new failures (<m> pre-existing on main)
- substitution: flux envsubst --strict ok; literal $ handled how
- helm template: <chart@ver>; new keys effective: yes/no (diff lines); postRenderers hit only <target>
- flux-local test: <N passed> (main <M passed>); new failures: none | <list>
- server dry-run: CRDs ok | PSA <level> ok | namespace label ok
- live PromQL/LogQL parse: ok
```
