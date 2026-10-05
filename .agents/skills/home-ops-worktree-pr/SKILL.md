---
name: home-ops-worktree-pr
description: Takes one agent-led change in home-ops from an isolated git worktree (created with Worktrunk `wt`) to a pushed branch and PR, or a direct push to main only when the user explicitly asks. Covers credential wiring so kubectl/sops/talosctl work, overlapping-PR checks, lefthook-safe commits, stacked PRs, CI watch and cleanup. Use at the start of any implementation task, when kubectl fails inside a worktree (localhost:8080, x509 expired), or when asked to "open a PR", "push to main" or "commit just my changes".
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
    If the toplevel is `/opt/home-ops`, you're in the owner's checkout. Run `wt list` (from `/opt/home-ops`) to see existing worktrees with their ahead/behind and change status; pick an unused branch name and check whether one already covers your area.
2. **Create the worktree off `origin/main` with Worktrunk** (`wt`, pinned in mise). Always pass `--base origin/main`: the default base is local `main`, which is often behind in the owner's checkout. `--no-cd` because agents have no shell integration; `--format json` returns the path.
    ```sh
    cd /opt/home-ops && git fetch -q origin
    wt switch --create <type>/<slug> --base origin/main --no-cd --format json   # {"path":"/opt/home-ops.<type>-<slug>",...}
    ```
    Without `wt`: `git -C /opt/home-ops worktree add -b <type>/<slug> /opt/home-ops.<type>-<slug> origin/main`, then create the symlinks in step 3 by hand.
    If a tool already created the worktree elsewhere (`/tmp/wt-*`, a subagent runner), keep it and use `git rev-parse --show-toplevel` as `<wt>` below.
3. **Confirm the credential symlinks.** The `pre-start` hook in `.config/wt.toml` symlinks `kubeconfig`, `age.key` and `talos/clusterconfig/talosconfig` from `/opt/home-ops` and runs `mise trust`. Symlinks, not copies or an exported `KUBECONFIG`: mise resolves those env vars from `{{config_root}}` (the worktree) and its directory hook resets exports.
    ```sh
    cd <wt> && mise env | rg 'KUBECONFIG|SOPS_AGE_KEY_FILE|TALOSCONFIG'
    kubectl get nodes -o name && git status --short    # nodes listed; status must be empty
    ```
    **Unapproved hook**: until the owner runs `wt config approvals add` once, `wt switch --create` in a non-interactive shell fails with `Cannot prompt for approval in non-interactive environment` and creates nothing. Don't pass `--yes` to get past it; re-run with `--no-hooks` and create the links by hand: `ln -s /opt/home-ops/<f> <f>` for each file, then `mise trust -q .`. Same for worktrees not made by `wt`.
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
11. **Clean up only what you started**: your port-forwards by PID and `/tmp` files with decrypted data. Remove **your own** worktree once its PR has merged: `wt remove <type>/<slug>`. It deletes the branch only if its changes are already on `main` (squash merges included), and otherwise keeps it. While the PR is open, leave it. Never remove other worktrees; point the user at `wt list` for stale ones.

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
- **Worktrunk commands to avoid**: `wt merge` (squash-merges into local `main`, bypassing PR and CI), `wt step commit`/`squash` (LLM-written messages, not Conventional Commits with a rationale), `wt step copy-ignored` (copies `age.key` instead of linking it).
- **Worktree paths**: `wt` creates `/opt/home-ops.<type>-<slug>`. Older worktrees use `/opt/home-ops-<slug>`, `/tmp/wt-*` or `~/.config/superpowers/worktrees/`; `wt list` and `wt remove` handle them all.
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
