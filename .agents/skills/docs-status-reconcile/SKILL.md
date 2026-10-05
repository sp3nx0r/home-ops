---
name: docs-status-reconcile
description: Brings home-ops docs/ (plans, punch-lists, evaluations, runbooks) and AGENTS.md back in line with recent changes. It scopes the docs from the git log or the current session's PRs, verifies each claim against GitHub, the repo and the live cluster, edits by doc type, and moves finished plans to docs/completed/ without touching the owner's uncommitted drafts. Use when asked to "update the docs", "what's still outstanding" or "mark X done", after a batch of PRs merges, or at the end of a session that shipped changes.
---

# Docs status reconcile

## Mission

Make the docs that recent changes touch match merged PRs, open PRs, the repo and the live cluster, with every status change backed by a check and without overwriting anyone's work in progress.

## Prerequisites

- Edits go to `docs/` and `AGENTS.md`. Cluster access is read-only (`source scripts/o11y.sh` for queries).
- Untracked or modified docs in `git status` are the owner's drafts. Edit them in place in the main checkout if they're in scope, never copy them into a worktree, and don't commit them unless asked.
- Docs layout: top-level `docs/*.md` are active; `docs/completed/` are finished plans (kept for history); `docs/archived/` is out of scope; `docs/runbooks/` and `docs/backup-and-recovery/` are living runbooks.

## Workflow

1. **Scope from what changed**, using [scope.sh](scope.sh). It extracts app, skill and file names plus PR numbers from the changes and lists the docs that mention them, ranked by hits:
    ```sh
    S=.agents/skills/docs-status-reconcile/scope.sh
    $S                              # non-Renovate commits on main since the last commit that touched docs/
    $S 'origin/main@{7.days.ago}'   # or since any rev
    $S --prs <n> <n> ...            # session context: the PRs this session opened or merged
    git status --short docs AGENTS.md   # owner WIP
    ```
    - Use `--prs` at the end of a session; it includes open PRs, which aren't on `main` yet.
    - The hit list is candidates. Open each one with `rg -n -w -F -e <term> <doc>` and drop docs where the hit is incidental (an app named in passing).
    - Also check `docs/completed/` for docs whose subject changed. A completed plan that's now wrong gets a dated note, not a rewrite.
    - Explicit user scope ("update the kubescape doc") wins; still run the script to catch siblings.
2. **Resolve every PR reference in the scoped docs in one pass**, plus related merged work the docs never mention:
    ```sh
    F="<scoped docs>"
    for n in $(rg -o '#[0-9]{3,4}' $F --no-filename | sort -u | tr -d '#'); do
      gh pr view $n --json number,state,mergedAt,title \
        --jq '"\(.number) \(.state) \(.mergedAt // "-" | .[0:10]) \(.title)"' 2>/dev/null || echo "$n not-a-PR"; done
    gh pr list --state open --limit 50 --json number,title,isDraft --jq '.[] | "\(.number) draft=\(.isDraft) \(.title)"'
    ```
3. **List concrete claims** from each scoped doc (read it in full, plus `git diff <doc>` for WIP): "X is open", "Hubble disabled", "PVC is 50Gi", "LB .26 = foo", "only allows host".
4. **Verify each claim** against the source of truth:
    - Repo: `rg -n '<setting>' kubernetes/`, `git log --oneline -S '<string>' -- kubernetes`.
    - Cluster: `kubectl get <kind> ...`, `q '<promql>'`.
    - Open PR intent: `gh pr view <n> --json body --jq .body | rg -i '<topic>'`.
    - Docs describing a live object (a CCNP, an alert's exclusions, a SecurityPolicy list): diff against the actual manifest. Later commits widen rules.
5. **Edit by doc type**:
    - **Punch-lists**: rewrite freely. Move merged items to a "verified" table saying what was checked; list open PRs with blocker / post-merge check; bump the "as of" date.
    - **Plans**: move findings Open → Resolved with the PR list; fix sequencing checkboxes.
    - **Point-in-time evaluations**: keep the findings intact; add a dated "Status update" table (finding → PR/state).
    - **Runbooks**: status line (`READY` → `LIVE since <date> ([#n](https://github.com/sp3nx0r/home-ops/pull/<n>))` → `COMPLETE`); replace "this PR" with the real number; remove sentences that point at deleted content.
    - **AGENTS.md**: only facts every agent needs (namespace table, tooling, conventions). Link to the doc rather than copying procedure.
6. **Complete a doc only when every step is verified**: `git mv docs/<x>.md docs/completed/<x>.md`, then `rg -n '<x>.md' docs AGENTS.md .agents | rg -v completed/` and fix every link.
7. **Sweep for leftovers** in the scoped docs: `rg -n -i 'not yet merged|once #|awaiting|this PR|in progress|is disabled|TODO' $F`.
8. **Format** only the markdown you edited: `oxfmt <files>`.
9. **Final `git status --short`.** Any file you didn't edit that changed is someone else's concurrent work; report it, don't touch it.

## Gotchas & Edge Cases

- **Don't overclaim from absence.** A cert-manager fix with no renewal since merge, or a path with no events in 72h, is "unverified", not "done". List these as "checks only you can finish" with the date they become testable.
- **Unmentioned merges are the usual miss.** One pass found #535 still listed as "awaiting merge" after it had merged, and #552–#562 not mentioned at all. Scoping from the git log, not from the PR numbers already in the doc, is what catches these.
- **Concurrent sessions edit the same files** (the kubescape HelmRelease and `docs/kubescape.md` changed underneath an agent). Re-read before each edit and confirm your earlier edits survived.
- **Verify your own corrections.** Recount numbers (84 endpoints was really 81) and re-check config before explaining a drop.
- **Docs that describe a live object drift.** The floor runbook said ingress allowed only `host`; the CCNP also allowed `remote-node`, `kube-apiserver` and `health`.
- **Things that vanished** (an LB IP absent from git history): state the current state with a date; don't invent history.
- Put each learning in one place and cross-reference it.
- A `git mv` stages the rename; say exactly what is staged if you offer a `docs:` commit.

## Output Template

```
Scope: <git range | PRs #a #b> → <N> docs (<M> dropped as incidental)
Updated <N> docs to match main, open PRs and the cluster. Nothing committed.
What was stale:
- <doc>: <claim> → <reality> ([#n](https://github.com/sp3nx0r/home-ops/pull/<n>))
Moved: <doc> → docs/completed/ (links fixed in <files>)
Checks only you can finish: <item — testable from <date>>
Not touched (someone else's WIP): <files>
```
