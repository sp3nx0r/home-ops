---
name: flux-rollout-watch
description: Gates a home-ops app PR before merge and proves the Flux rollout after merge, including recovery of Failed, Stalled or rolled-back HelmReleases. Use when the user says "review PR #N before I merge", "merged, watch it", "is it healthy", when a HelmRelease is Failed/Stalled, a Helm hook Job times out, or the Flux Local check is red.
---

# Flux rollout gate and watch

## Mission

Decide from evidence whether a change is safe to merge, then prove it is running and doing its job. Never infer success from "Job Complete" or a quiet minute.

## Prerequisites

- Query helpers (no port-forwards): `source scripts/o11y.sh` from inside the repo gives `q`/`qr` (Prometheus), `lq`/`lqr` (Loki) and `am` (active alerts).
- Every HelmRelease is patched by `kubernetes/flux/cluster/ks.yaml`: install `RetryOnFailure`; upgrade `RemediateOnFailure` with `retries: 2` and `remediateLastFailure: true`; `cleanupOnFail`. A failed upgrade rolls back after the retries, then goes `Stalled`.
- **App Kustomizations live in the app's namespace**, not `flux-system`: `flux get ks -A | rg <app>`, then use `-n <ns>`.
- Related skills: `cilium-cnp-authoring` (writing the fix), `hubble-drop-triage` (finding the drop).

## Workflow

### A. Pre-merge gate (PR review)

1. `gh pr view <n> --json title,mergeable,mergeStateStatus,files,statusCheckRollup` and `gh pr diff <n>`.
2. Record a baseline so new breakage is attributable:
    ```sh
    flux get ks -A --status-selector ready=false; flux get hr -A --status-selector ready=false
    kubectl get apiservice | rg -v True; kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
    ```
3. Check out the PR head without touching anyone's working tree and render it:
    ```sh
    git fetch origin pull/<n>/head && git worktree add --detach /tmp/pr-<n> FETCH_HEAD
    kustomize build /tmp/pr-<n>/kubernetes/apps/<ns>/<app>/app
    yq '.spec.values' /tmp/pr-<n>/kubernetes/apps/<ns>/<app>/app/helmrelease.yaml > /tmp/pr-<n>-values.yaml
    helm template <app> oci://<url-from-ocirepository.yaml> --version <tag> -f /tmp/pr-<n>-values.yaml
    ```
    `${VAR}` substitutions stay literal in the render; that's fine for review. Postrenderers in the HelmRelease aren't applied, so check them by hand.
    Check the output against the PR's claims:
    - Pod labels, container/probe ports and `hostNetwork` vs the CNP `endpointSelector`/`toPorts`; rendered service URLs vs allowed egress.
    - RBAC: anything on `secrets`, `*` or write verbs; what aggregates into `view`/`edit`.
    - Single-replica Deployments with RWO iSCSI PVCs need `strategy: Recreate`, or Multi-Attach stalls the update.
    - New alert metrics exist (`q 'count(<metric>)'`) and don't duplicate a chart's built-in alert.
    - Upstream claims ("X never needs egress"): read the source at the pinned tag (`gh api repos/<o>/<r>/contents/<path>?ref=<tag> -q .content | base64 -d`).
4. `git worktree remove /tmp/pr-<n>` when done.

### B. Red Flux Local

The workflow runs only on `pull_request`, so `main` can break without anyone noticing. Before blaming the PR:

```sh
git fetch -q origin && git log --oneline <pr-base>..origin/main
gh run view <run> --log-failed | rg -i -C2 'error|fail|assert'
```

Then run the failing step against `origin/main` in a detached temp worktree. If main fails on its own, report it and offer a separate fix. When fixing a contract test (`tests/volsync-cache-scrub.sh`), mutation-test it: the old regression and each targeted mutant must fail with the intended message.

### C. Post-merge watch

1. Confirm the merge commit is on `origin/main`. Then (ask first; it's a live action) run `just reconcile`, or `flux reconcile ks <app> -n <ns> --with-source`. `just kube sync ks` force-syncs **every** Kustomization; avoid it for one app.
2. Bounded wait, collecting evidence in the same call:
    ```sh
    timeout 300 kubectl -n <ns> rollout status deploy/<app> --timeout=280s; \
    flux get ks <app> -n <ns>; flux get hr -n <ns>; kubectl -n <ns> get pods,pvc,cnp
    kubectl -n <ns> get events --sort-by=.lastTimestamp | tail -15
    ```
3. **Pods hang (init stuck, startup probe failing, logs stop after "creating client")? Check policy before app config.** A missing CNP looked like a Kyverno bug ([#524](https://github.com/sp3nx0r/home-ops/pull/524) → [#563](https://github.com/sp3nx0r/home-ops/pull/563)). Run `q 'sum by (source,reason) (increase(hubble_drop_total{source=~"<ns>/.*"}[15m]))'`, then use `hubble-drop-triage`.
4. Blast radius before any fix: `kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations | rg -i '<app>|NAME'`. A `failurePolicy: Fail` webhook with an unreachable backend blocks unrelated API writes.
5. Verify on the **newest** pod. `deploy/<app>` can resolve to a Terminating pod:
    ```sh
    POD=$(kubectl -n <ns> get pods -l app.kubernetes.io/name=<app> --field-selector=status.phase=Running \
      --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1:].metadata.name}')
    kubectl -n <ns> logs $POD -c <c> --tail=40; kubectl -n <ns> logs $POD -c <c> --previous --tail=20
    ```
    Check the rendered artifact live (ConfigMap data, container args) and the behaviour through the app's own API. A file on disk doesn't prove the app loaded it.
6. Alerts: `am` and `q 'ALERTS{namespace="<ns>"}'`. RBAC denials from the new ServiceAccount:
    ```sh
    lq 'sum by (user_username, objectRef_resource, verb) (count_over_time({source="kube-audit"} | json | responseStatus_code="403" [30m]))'
    ```
    404 and 409 are normal get-then-create noise; explain every 403.
7. Scheduled work: wait for warm-up, then trigger **one at a time** against a baseline:
    ```sh
    T0=$(date -u +%Y-%m-%dT%H:%M:%SZ); kubectl -n <ns> create job --from=cronjob/<cj> <cj>-manual-$(date +%s)
    kubectl -n <ns> wait --for=condition=complete job/<name> --timeout=300s
    kubectl -n <ns> logs deploy/<worker> --since-time=$T0 | tail -50
    ```
    Compare result counts against the baseline, then delete the manual Jobs and re-list to confirm.

### D. Recover a Failed / Stalled HelmRelease (ask before running)

1. Find the cause: `kubectl -n <ns> describe hr <app> | sed -n '/Status:/,$p'`, `helm -n <ns> history <app> --max 5`, hook Jobs/pods (`kubectl -n <ns> get jobs,pods -l app.kubernetes.io/instance=<app>`).
2. **Hook Job hangs → check the hook pod's CNP.** Hook pods carry different labels or need ports the app's CNP doesn't allow (garage-configure → admin `:3903`). Logs can mislead ("Resolving coordinator" while DNS was fine); test each step. Confirm the fixed CNP is live with `kubectl -n <ns> get cnp <n> -o json | jq '[.spec.ingress[].toPorts[].ports[].port]'` rather than `flux reconcile ks --with-source`, which blocks on the stalled HelmRelease's health check.
3. Retry once the fix is live:
    - Failed install: `flux reconcile hr <app> -n <ns> --force`.
    - Stalled upgrade (retries exhausted): `flux reconcile hr <app> -n <ns> --reset`.
4. **Rollback cascade.** A timed-out upgrade rolls back, which re-creates the old StatefulSet template and undoes any `kubectl delete sts --cascade=orphan`. Later retries fail with `volumeClaimTemplates ... immutable`. Redo the orphan-delete, then `--reset`.
5. A hook that completes late after a rollback ran with the **old** values (Garage kept its old layout size on a resized disk). Verify in the app itself (`kubectl -n storage exec garage-0 -- /garage status`).

## Gotchas & Edge Cases

- Restart counts from before the fix are noise. Report "N restarts, all before <time>, none since".
- Completed hook Job pods show `READY false`; that's expected.
- A hook pod matching the app's metrics Service selector produces `TargetDown` until it's gone. Don't chase it separately.
- Unrelated unready Kustomizations (dependents waiting on a Renovate rollout): check the dependency, reconcile the dependents, and don't attribute them to your change.
- Hook scripts can expose admin tokens in `ps` argv. Never paste `ps` output; mention rotation.
- CronJob schedules are UTC; the owner is UTC-5. Size lookbacks (`max_over_time(ALERTS{...}[15h])`) to cover the run.
- A manual trigger before warm-up can flood a worker queue (kubevuln queued ~116 registry pulls and caused a drop storm). Restart the worker to flush it.
- Kill background port-forwards by PID, never with a chained `pkill -f`; it has killed the agent's own shell.

## Output Template

```
Verdict: <safe to merge | merge after X | deployed and healthy | degraded: …>
Evidence: ks/hr Ready at <time> · pods <newest, restarts since> · CNP VALID · drops <none/list> · alerts <none/list> · 403s <explained>
Functional proof: <API response / job results vs baseline>
Recovery run: <commands, or "none needed">
Unrelated issues seen: <…>
```
