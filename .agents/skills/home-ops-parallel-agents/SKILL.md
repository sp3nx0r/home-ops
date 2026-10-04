---
name: home-ops-parallel-agents
description: Orchestrates several background agents in home-ops that each build one change in its own git worktree and open a PR. Covers collision planning on hot files, cross-agent contracts, a paste-in prompt block, verifying agent claims before relaying them, and a cross-PR compatibility pass before merge. Use when the user asks to "spin off agents", "fork agents", "do these in parallel", or open several PRs or plans at once.
---

# home-ops: parallel worktree agents

## Mission

Run N independent implementation agents without them clobbering the owner's checkout, each other, or the live cluster, and land N PRs that merge in any order (or in a stated order).

## Prerequisites

- Each agent follows `home-ops-worktree-pr`. That skill owns the per-agent rules (worktree setup, hot files, commits, stacking, cleanup). This skill covers only the orchestrator's job.
- Task tool with `subagent_type: generalPurpose`, `run_in_background: true`; `resume: <agent-id>` to continue one. Prefer `generalPurpose` with the agent creating its own worktree via `wt switch --create` (credential symlinks come from the `.config/wt.toml` hook). `best-of-n-runner` creates its own worktree outside `wt`, so that agent must symlink credentials at its own toplevel by hand.
- Check the owner has approved the project hook (`wt config approvals add`), or every agent's worktree comes up without credentials.
- Subagents don't load skills reliably, so paste the prompt block below into every prompt.

## Workflow

1. **Pre-flight (orchestrator, read-only):**
    ```sh
    git -C /opt/home-ops fetch -q && git -C /opt/home-ops status -sb   # owner checkout: often behind, holds untracked docs
    (cd /opt/home-ops && wt list)                                      # existing worktrees; choose unique branch names
    gh pr list --state open --json number,headRefName,title -q '.[]|"\(.number) \(.headRefName) \(.title)"'
    ```
2. **Assign hot files.** Take the list in `home-ops-worktree-pr` step 6 and give each hot file to one agent, or tell the others to touch it minimally and expect a rebase. Orchestrator-level additions:
    - `kubernetes/apps/storage/garage/app/*` (buckets/keys): one agent at a time.
    - `kubernetesTalosAPIAccess` in Talos: a flat allow-list, so any allowed namespace gets every allowed role. Don't let an agent widen it without asking.
    - Distinct LoadBalancer IPs: pre-assign them, or have agents grep all worktrees for `lbipam.cilium.io/ips`.
3. **Define cross-agent contracts up front** when one PR consumes another's output, and state them identically in both prompts. Example from [#554](https://github.com/sp3nx0r/home-ops/pull/554): the ruler loads ConfigMaps labeled `loki_rule: "true"`, so the canary PR ships its rules that way. If B can't work without A's files, tell B to stack on A (see `home-ops-worktree-pr` step 6).
4. **Paste this block into every prompt**, then add the task, the agent's slug, its hot-file assignments and any contracts:
    ```text
    Repo rules (home-ops; condensed from .agents/skills/home-ops-worktree-pr — read it if you can):
    - Work only in your own worktree. Never edit or `git switch` in /opt/home-ops.
       cd /opt/home-ops && git fetch -q origin
       wt switch --create <type>/<slug> --base origin/main --no-cd --format json   # prints the path
     A hook symlinks kubeconfig/age.key/talosconfig and runs mise trust; confirm `kubectl get nodes` works
     there. If the links are missing: ln -s /opt/home-ops/<f> <f> for each, then mise trust -q .
     Set working_directory on every Shell call; use rg in Shell, not Grep/Glob, for worktree files.
    - Never use `wt merge`, `wt step commit` or `wt step copy-ignored`.
    - Read AGENTS.md and docs by absolute path under /opt/home-ops/docs/. Don't edit untracked owner docs.
    - Cluster is READ-ONLY: get/logs/--dry-run=server/auth can-i/apiserver-proxy queries (source scripts/o11y.sh).
      No apply/patch/delete/flux reconcile/talosctl apply; no B2, Pocket ID or UniFi changes. Write those as
      manual steps in the PR body.
    - Every new app ships a CiliumNetworkPolicy; every new namespace a PSA enforce label.
    - SOPS: encrypt immediately (sops --encrypt --in-place); never print decrypted values. Placeholders must be
      inert (.invalid hosts), with the exact `sops set` command in the PR body.
    - git add explicit paths only (never -A); Conventional Commit subject + rationale body; never --no-verify.
    - No `pkill -f`. Kill background processes by PID.
    - Open a PR against main (draft for Talos/RBAC/alerting/placeholder secrets). Never merge.
    - Final answer: PR link, files touched, validation run, manual steps before merge, anything unverified.
    ```
    For research-heavy work ("Harbor or Zot?"), run a **research-only** phase that returns options and questions, then stops.
5. **Launch all agents in one message.** Tell the user each scope, the inter-PR dependencies, and that nothing is applied live.
6. **Verify each completion before relaying.** Re-check the headline claim yourself (`rg` the config it says is wrong; a PromQL query for a capacity claim). Adjust severities with context: e.g. an unbacked Prometheus PVC matters little when Thanos ships blocks to Garage.
7. **Relay only decisions that change the build** (AskQuestion), then `resume` the same agent id with the answers.
8. **Cross-PR pass** once several PRs are up:
    ```sh
    for p in <prs>; do gh pr view $p --json number,mergeable,statusCheckRollup \
      -q '"#\(.number) \(.mergeable) \([.statusCheckRollup[].conclusion]|unique|join(","))"'; done
    for p in <prs>; do gh pr view $p --json files -q '.files[].path'; done | sort | uniq -d   # textual overlaps
    ```
    - Run one PR's validators on another's artifacts (e.g. the ruler branch's linter on the canary rules).
    - Hunt semantic conflicts. Example: a ruler pointed at the Alertmanager Service while another PR scaled Alertmanager to 2 replicas. The fix was `dnssrvnoa+http://_http-web._tcp.alertmanager-operated.o11y.svc.cluster.local`.
    - Back-port conventions that a later PR established (e.g. `allocateLoadBalancerNodePorts: false`).
    - State the merge order; stacked PRs need a rebase after their base squash-merges.
9. **Summarize** with the Output Template.

## Gotchas & Edge Cases

- **Agents edit the owner's checkout anyway.** Check `git -C /opt/home-ops status --short` and `git -C /opt/home-ops branch --show-current` after they finish, and report any change.
- In-repo linters may reject paths outside their repo. Copy into a temp dir inside that worktree, lint, delete, and check `git status --porcelain`.
- Amending another agent's unmerged branch: `--force-with-lease`, and say so.
- Closing a superseded PR is fine after the user decides. Comment the reason and keep the branch.
- Don't remove other agents' worktrees; list them for the user (`wt list`). Each agent removes its own after merge with `wt remove <branch>`.

## Output Template

```markdown
All N agents finished; nothing was applied to the cluster.

| PR                                                   | Purpose | CI    | Blocking before merge    |
| ---------------------------------------------------- | ------- | ----- | ------------------------ |
| [#NNN](https://github.com/sp3nx0r/home-ops/pull/NNN) | …       | green | set `X` via `sops set …` |

**Merge order:** #A first (#B consumes its rule loader); #C independent. #B and #C both edit `AGENTS.md`, so the second needs a rebase.
**Claims I re-verified / downgraded:** …
**Cross-PR fixes pushed:** …
**Decisions needed:** …
```
