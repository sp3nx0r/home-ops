---
name: home-ops-worktree-pr
description: Takes one agent-led change in home-ops from an isolated git worktree to a pushed branch and PR, or a direct push to main only when the user explicitly asks. Covers credential wiring so kubectl/sops/talosctl work, overlapping-PR checks, lefthook-safe commits, stacked PRs, CI watch and cleanup. Use at the start of any implementation task, when kubectl fails inside a worktree (localhost:8080, x509 expired), or when asked to "open a PR", "push to main" or "commit just my changes".
---

# home-ops: worktree → PR

## Mission

Ship one focused change from a fresh worktree to a reviewable PR without touching the owner's checkout, other agents' worktrees, or the live cluster.

## Prerequisites

- Primary checkout `/opt/home-ops` belongs to the owner. It often holds uncommitted/untracked docs and is often behind `origin/main`. Never edit it, never `git switch` in it (switching removes branch-only files from the owner's working tree and can carry their untracked files onto your branch).
- mise sets `KUBECONFIG`, `SOPS_AGE_KEY_FILE`, `TALOSCONFIG`, `SOPS_CONFIG` from `{{config_root}}` (see `.mise/config.toml`). In a worktree these resolve **inside the worktree**, where the gitignored files don't exist.
- Running several agents at once: `home-ops-parallel-agents` (it embeds a condensed copy of this skill's rules for agent prompts).

## Workflow

1. **Check where you are, even if the prompt says you're in a worktree.**
    ```sh
    pwd; git rev-parse --show-toplevel; git status -sb | head -3
    git -C /opt/home-ops fetch -q origin && git -C /opt/home-ops worktree list
    ```
    If the toplevel is `/opt/home-ops`, you're in the owner's checkout. 30+ worktrees exist; pick an unused slug and check whether one already covers your area.
2. **Create the worktree off `origin/main`** as a sibling, `/opt/home-ops-<slug>`. If `just --list worktree` works (PR [#491](https://github.com/sp3nx0r/home-ops/pull/491)), use `just worktree new <slug> [feat|fix]`. Otherwise:
    ```sh
    git -C /opt/home-ops worktree add -b <type>/<slug> /opt/home-ops-<slug> origin/main
    ```
    If a tool already created the worktree elsewhere (`/tmp/wt-*`, a subagent runner), keep it and use `git rev-parse --show-toplevel` as `<wt>` below.
3. **Wire the gitignored credentials with symlinks** (the #491 recipe doesn't). Symlinks make mise resolve correctly; an exported `KUBECONFIG` can be reset by mise's directory hook.
    ```sh
    cd <wt>
    ln -s /opt/home-ops/kubeconfig kubeconfig
    ln -s /opt/home-ops/age.key age.key
    ln -s /opt/home-ops/talos/clusterconfig/talosconfig talos/clusterconfig/talosconfig   # if talosctl is needed
    mise trust -q . && mise env | rg 'KUBECONFIG|SOPS_AGE_KEY_FILE|TALOSCONFIG'
    kubectl get nodes -o name && git status --short    # nodes listed; status must be empty
    ```
4. **Pin every Shell call to the worktree** with `working_directory: <wt>`. A `cd /tmp/...` persists into later calls and silently drops mise env. For files outside the workspace root, use `rg` in Shell rather than the Grep/Glob tools, which have returned main-checkout results.
5. **Read docs the user mentions from `/opt/home-ops/docs/`.** Untracked owner docs (e.g. `docs/sre-and-security-evaluation.md`, `docs/hardening-outstanding.md`) don't exist in worktrees. Don't edit or commit them; the repo is public.
6. **Check overlapping open PRs before editing a hot file.** These are edited by most branches:
    - `kubernetes/apps/o11y/kube-prometheus-stack/app/helmrelease.yaml` (Alertmanager receivers/routes, Prometheus args)
    - `talos/control-plane/00-cluster.yaml` (prefer a new numbered patch file under `talos/all/` or `talos/control-plane/`)
    - `AGENTS.md` (namespace table, tooling list), `justfile` `mod` lines, `.mise/config.toml`
    - `kubernetes/components/sops/cluster-secrets.sops.yaml`
    ```sh
    gh pr list --state open --json number,headRefName,title -q '.[] | "\(.number) \(.headRefName) \(.title)"'
    gh pr diff <n> --name-only
    ```
    Record expected conflicts and functional interactions in the PR body.
    **Stacking:** base on `origin/main` by default. Stack on another PR's branch only for a hard dependency (your change uses a file only that PR adds): `gh pr create --base <their-branch>`, and say so at the top of the body. This repo squash-merges, so once the base merges, replay only your commits with `git rebase --onto origin/main <last-commit-of-base-branch>`, then `git push --force-with-lease`.
7. **Implement and validate.** Run the checks that match what you touched, from the worktree:
    - Kubernetes: `kustomize build kubernetes/apps/<ns>/<app>/app`, a server dry-run (`kubectl apply --dry-run=server -f`) of new or changed CRs, and `helm template` with the HelmRelease values for chart changes. CI runs flux-local on the PR.
    - Talos: `talos-config-change`. Renovate-visible versions and digests: `renovate-tracking-and-pinning`. Network policy: `cilium-cnp-authoring`.
    - Scripts: `shellcheck`. Docs: `oxfmt` runs in the hook.
    - Chart values can render as env-var references (Headlamp `usePKCE: true` → `$(OIDC_USE_PKCE)`); a missing Secret key means CrashLoop. Render with real values.
      Secrets: see Gotchas.
8. **Commit per concern.** Conventional Commit subject, rationale body, via heredoc:
    ```sh
    git add <explicit paths>          # never `git add -A` (caught __pycache__, symlinks, owner files)
    git diff --cached --stat          # anything you didn't intend is swept in
    git commit -q -F - <<'EOF'
    fix(<scope>): <imperative summary>

    <why it was needed, then key implementation notes>
    EOF
    git status --short                # lefthook oxfmt has stage_fixed=true; confirm nothing left unstaged
    ```
    Let lefthook run (SOPS check, TruffleHog, oxfmt, shellcheck, actionlint/zizmor). Never `--no-verify`.
9. **Rebase if main moved, then push and open the PR.** Write the body to a file; inline `--body` breaks on backticks. Use absolute GitHub URLs for repo links (relative links break on PR pages).
    ```sh
    git fetch -q origin && git log --oneline HEAD..origin/main   # non-empty → rebase and re-validate
    git push -u origin <type>/<slug>
    gh pr create --base main --title "<type>(<scope>): ..." --body-file /tmp/pr-<slug>.md [--draft]
    ```
    Use `--draft` for Talos, RBAC, alerting, or anything with placeholder secrets. Don't merge.
10. **Watch CI with a timeout**, not a foreground `sleep`. Checks take a minute to register.
    ```sh
    timeout 900 gh pr checks <n> --watch --interval 20 > /tmp/checks-<n>.txt 2>&1; tail -15 /tmp/checks-<n>.txt
    ```
    Flux Local runs only on `pull_request` and only meaningfully for `kubernetes/**`. A red check may come from `main`; see `flux-rollout-watch` ("Red Flux Local").
11. **Clean up only what you started**: your port-forwards by PID and `/tmp` files with decrypted data. Remove **your own** worktree once its PR has merged (`just worktree remove <slug>`, or `git -C /opt/home-ops worktree remove <wt>`). While the PR is open, leave it. Never remove other worktrees; list stale ones for the user (`just worktree nuke` is the owner's call).

## Direct push to main (only when the user asks)

1. `git -C /opt/home-ops status --short` and `git diff --cached --stat`: write down what is the user's.
2. Whole files that are yours: `git add <file>`. Mixed files: build the staged blob from `HEAD` plus your block (don't regex-split `git diff -U0` hunks; they misapplied once):
    ```sh
    git show HEAD:<file> > /tmp/base   # insert your block at a unique anchor → /tmp/staged
    git update-index --cacheinfo 100644,"$(git hash-object -w /tmp/staged)",<file>
    git diff --cached <file>; git diff <file>   # yours staged; only the user's edits remain unstaged
    ```
    Or commit one path at a time: `git commit -F - -- <path>`.
3. `git pull --rebase origin main && git push origin main`. Renovate and parallel sessions move main constantly.
4. If you swept in the user's change, say so; never rewrite pushed history on main.

## Gotchas & Edge Cases

- **SOPS.** Write plaintext, then `sops --encrypt --in-place <f>` immediately and check `grep -c 'ENC\[' <f>`. To change one value: `sops set <f> '["stringData"]["KEY"]' '"value"'`. Inspect keys only: `sops -d <f> | yq '.stringData | keys'`. A `sed` redaction and `sops -d | rg -v pass` both leaked real values in past sessions.
- **Comments inside `stringData` get encrypted** into `ENC[...]`. Put comments above `stringData:` before encrypting.
- **Multi-document SOPS files**: `sops set` edits the first document. Confirm with `sops -d f | yq '.metadata.name, (.stringData|keys)'`.
- **Placeholders must be inert and flagged.** `REPLACE_WITH_*` values deploy on merge and are readable in-cluster; an unfilled Alertmanager URL fires a critical alert. Use `.invalid` hosts, never a real public endpoint (an `ntfy.sh/REPLACE` placeholder would have published alerts publicly). Mark the PR "do not merge until filled" with the exact `sops set` command.
- **`pkill -f '<pattern>'` killed the agent's own shell** in many sessions (the pattern is in its own command line). Kill by PID (`cmd & PF=$!; ...; kill $PF`) or avoid port-forwards entirely (`o11y-history-forensics`).
- **Shell aliases**: `find` is `fd`, `ls` adds color codes, `cp` may be interactive. Use `command find`, globs, `command cp -f`.
- **Picking a LoadBalancer IP**: check live `.status.loadBalancer.ingress` and grep all worktrees (`git worktree list`) for `lbipam.cilium.io/ips`; an open branch may already claim it.
- **Pushes can hang on SSH prompts**: `GIT_SSH_COMMAND='ssh -o BatchMode=yes' timeout 60 git push ...`.
- **`git checkout main` fails inside a worktree** (main is checked out elsewhere). Branch from `origin/main` instead.
- **Read-only cluster by default**: `get`, `logs`, `--dry-run=server`, `auth can-i`, proxy queries. No apply/patch/delete/`flux reconcile` unless asked. Your own `kubectl exec` shows up in the audit log as an admin exec.

## Output Template

```
PR: [#<n> <title>](https://github.com/sp3nx0r/home-ops/pull/<n>) (draft?) — branch <type>/<slug>, base origin/main <sha>
CI: <green | failing check + cause (PR or main?)>
Commits: <sha> <subject> …
Validation: <checks run and results>
Before merge: <exact sops/manual steps, or "none">
Conflicts/interactions: <PR links + files>
Left alone: <owner's uncommitted files>
```
