---
name: renovate-tracking-and-pinning
description: Keeps home-ops dependencies visible to Renovate by pinning chart-rendered images to index digests, proving extraction with a local dry run, adding scoped customManagers for embedded versions, and tracing Dependency Dashboard warnings to their cause. Use when pinning an image digest, asking "is X tracked by Renovate", adding a version Renovate can't see, or when the Dashboard shows lookup failures, a duplicate dashboard or Repository Problems. Not for merging open Renovate PRs.
---

# Renovate tracking and pinning

## Mission

Make every version and digest in the repo something Renovate can see and update, and prove it with a local dry run instead of waiting for the weekend run.

## Prerequisites

- `.renovaterc.json5` extends `github>home-operations/renovate-presets#8.1.0`, `schedule: ["every weekend"]`, `ignorePaths: ["**/*.sops.*"]` (never annotate SOPS files). Repo `customManagers`/`packageRules` are **appended** to the preset's arrays; scalar keys (e.g. `dependencyDashboardTitle`) **override** them.
- Renovate runs as the hosted Mend app; logs are at `developer.mend.io/github/<owner>/home-ops`. Dry runs need a local `renovate` CLI (`brew install renovate`, or `npx --yes --package renovate renovate`). `skopeo`/`docker buildx imagetools` for digests.

## Workflow

### A. Is it tracked?

Tracked automatically: `image:` refs (docker; `pinDigests` on), HelmRelease charts via HelmRepository, OCIRepository tags, mise tools, `# renovate: datasource=… depName=…` annotations (the preset's annotated manager matches **every file** and captures only `datasource` + `depName`; no `extractVersion`, no `packageName`). **Not tracked**: values inside YAML block strings (`|`), plugin lists, scripts, and image `tag:` overrides without a sibling `repository`.

Read the preset at the pinned tag instead of guessing file names:

```sh
gh api 'repos/home-operations/renovate-presets/git/trees/8.1.0?recursive=1' -q '.tree[].path'
gh api 'repos/home-operations/renovate-presets/contents/default.json?ref=8.1.0' -q .content | base64 -d   # root is .json, not .json5
```

Presets under `apps/` (`talosFactory`, …) are opt-in, not pulled in by `default.json`.

### B. Pin chart-rendered images

1. List **every** image the component renders, including chart sidecars (the Loki gateway pod's first container was `access-log-exporter`, not nginx):
    ```sh
    helm pull oci://<chart> --version <v> --untar -d /tmp/chart
    rg -n 'define ".*image' -A12 /tmp/chart/*/templates/_helpers.tpl          # how registry/repository/tag/digest are joined
    kubectl -n <ns> get pod -l app.kubernetes.io/component=<c> -o json | jq '.items[0] | [.spec.containers[]|{name,image}], [.status.containerStatuses[]|{name,imageID}]'
    ```
2. Get the **index** (multi-arch) digest, not a per-platform one:
    ```sh
    docker buildx imagetools inspect docker.io/<repo>:<tag> | sed -n 1,3p
    ```
3. Write `registry`, `repository` and `tag` as siblings in one `image:` map, with the digest in `tag` (repo convention):
    ```yaml
    image:
        registry: docker.io
        repository: nginxinc/nginx-unprivileged
        tag: 1.31-alpine@sha256:<index-digest>
    ```
4. Render with the HelmRelease values and check the joined reference:
    ```sh
    yq '.spec.values' kubernetes/apps/<ns>/<app>/app/helmrelease.yaml > /tmp/values.yaml
    helm template <app> /tmp/chart/<chart> -f /tmp/values.yaml | rg 'image:'
    ```
    Expect `registry/repository:tag@sha256:…` with no doubled `@` or `:`.
5. **Prove extraction locally** on a throwaway copy:
    ```sh
    F=kubernetes/apps/<ns>/<app>/app/helmrelease.yaml
    rm -rf /tmp/rv && mkdir -p /tmp/rv/$(dirname $F) && cd /tmp/rv && git init -q \
      && cp /opt/home-ops/.renovaterc.json5 . && cp /opt/home-ops/$F $F && git add -A && git -c user.email=a@b -c user.name=a commit -qm init
    T=$(gh auth token)
    RENOVATE_GITHUB_COM_TOKEN=$T GITHUB_COM_TOKEN=$T LOG_LEVEL=debug LOG_FORMAT=json \
      renovate --platform=local --dry-run=lookup --onboarding=false --require-config=optional > /tmp/rv.log 2>&1
    rg -c 'Found .* package' /tmp/rv.log    # 0 → nothing extracted; check tokens before concluding
    jq -r 'select(.msg=="packageFiles with updates") | .config | to_entries[] | .key as $m | .value[] | .deps[]
      | select(.datasource=="docker") | "\($m)\t\(.depName)\t\(.currentValue)@\(.currentDigest // "-")"' /tmp/rv.log
    rm -rf /tmp/rv /tmp/rv.log
    ```
    Each image appears under both `flux` and `helm-values`; that's normal. To test updates, commit an older digest in the copy and expect a `digest` (or `patch` + `pinDigest`) proposal.

### C. Track an embedded version (customManagers)

1. Find the real release stream (`gh release list --repo <o>/<r>`, or tags filtered by package). Artifact Hub has no datasource; map packages to GitHub releases/tags.
2. Single repo with plain tags and the value on its own line: an annotation comment is enough. **Monorepo with per-package prefixes** (`headlamp-k8s/plugins`: `flux-0.7.0`): write a regex manager with `packageNameTemplate` (repo), `depName` (package), `extractVersionTemplate: "^{{{depName}}}-(?<version>.+)$"`, `versioningTemplate: "semver"`.
3. Prefer a multiline `matchStrings` over existing structure (`- name:` / `source:` / `version:`) to comments inside block strings, which would end up in rendered config. Avoid writing `datasource=X depName=Y` in a comment, which also triggers the preset's annotated manager and creates a duplicate dependency.
4. Scope `managerFilePatterns` to one file and pin a source-URL segment in the regex, so nearby `- name:` blocks (initContainers, parentRefs) don't match.
5. Validate: `timeout 180 npx --yes --package renovate renovate-config-validator .renovaterc.json5`, then test the regex with JS semantics against the real file (`node -e` with the JSON5 `\\` unescaped) and expect exactly N matches. Then run the B5 dry run.

### D. Dashboard triage

1. ```sh
   gh issue list --search "Renovate Dashboard in:title" --state all --json number,title,state,createdAt,updatedAt
   git log --oneline -15 -- .renovaterc.json5
   gh issue view <n> --json body -q .body | sed -n '1,80p'     # Repository Problems, Errored, Warning ("Files affected")
   ```
    A new dashboard within ~1h of a config merge means that merge caused it (renamed `dependencyDashboardTitle`: Renovate finds its issue by exact title; close the stale one).
2. **Orphaned custom datasources**: every `custom.<name>` used in the repo must be defined in `.renovaterc.json5` or an extended preset. Otherwise you get `Failed to look up custom.X … no-result` and that dependency **silently stops getting PRs**.
    ```sh
    rg -n 'datasource=custom\.' -g '!*.sops.*' . ; rg -n 'customDatasources' .renovaterc.json5
    ```
    Fix by pointing the annotation at a standard datasource already used for the same `depName` elsewhere. `siderolabs/talos` must use the same datasource in `talos/topf.yaml` and `kubernetes/apps/system-upgrade/tuppr/upgrades/talos.yaml` so they move together.
3. Verify on the next run: the warning disappears and a PR appears if an update is pending (`gh pr list --author app/renovate`).

## Gotchas & Edge Cases

- **A running digest that differs from the pin isn't proof the pin is wrong.** Upstream rebuilt a mutable tag after the nodes pulled it. Compare Docker Hub `last_updated` with node pull dates (`talosctl -n <node> image list --namespace cri | rg <repo>`).
- **Spegel resolves tags across peers** (`resolveTags` on by default), so `imagePullPolicy: Always` can still get a peer's stale digest for a mutable tag. Only a digest pin is reliable.
- **`latest@sha256:` pins hide major-version jumps** behind a "digest" update (e.g. `bitnami/kubectl:latest` in the cache-scrub CronJobs). Call it out.
- **Package-internal versions can lie** (`headlamp-cilium` `package.json` 0.1.0 vs image tag 0.1.11). Track the release tag or image digest.
- A PR body saying a datasource is "vestigial" may not cover every file; grep the whole repo.
- A reachable upstream endpoint doesn't prove a custom datasource is defined.
- Don't set `packageName` via `packageRules`; it has to come from the manager.
- Commit only your path when other files are staged: `git commit -F - -- <path>`.

## Output Template

```
Tracked before: yes/no — <manager/datasource or why not>
Pin: | container | image | pinned digest | running digest | upstream current? |
Renovate dry run: extracted by <managers>; update test <proposal>
customManagers: <scope, datasource, package, extractVersion>; validator ok; regex matches N
Dashboard: root cause <PR/sha, key removed>; impact <dep no longer updated>; fix <edit>; follow-up <close #N>
```
