---
name: upstream-scout
description: Review onedr0p/home-ops repo for recent interesting changes, filtering out Renovate dependency bumps. Use when the user wants to scout upstream changes, check what's new in onedr0p's repo, find novel homelab implementations, catch up on home-ops innovations, or mentions upstream review, onedr0p, or scouting for ideas.
disable-model-invocation: true
---

# Upstream Scout

Review onedr0p/home-ops for novel or interesting changes over a configurable time period, filtering out Renovate noise, and identifying implementations worth adopting.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| Time period | 7 days | How far back to look (`--since` format) |
| Repo | `onedr0p/home-ops` | Target repo to scout |

## Workflow

### Step 1: Gather Recent Merged PRs

Use the `gh` CLI to list recently merged PRs, excluding Renovate:

```bash
gh pr list \
  --repo onedr0p/home-ops \
  --state merged \
  --search "merged:>=$(date -d '7 days ago' +%Y-%m-%d) -author:app/renovate -author:bot-ross[bot]" \
  --limit 50 \
  --json number,title,mergedAt,body,files,url
```

Adjust the date calculation based on the requested time period. On macOS use `date -v-7d +%Y-%m-%d` instead.

If the user specifies a different time period, substitute accordingly (e.g., "2 weeks" → `14 days ago`, "month" → `30 days ago`).

### Step 2: Filter Out Noise

Discard PRs that are:
- Authored by `renovate[bot]`, `dependabot[bot]`, or `bot-ross[bot]`
- Titled with patterns like `chore(deps):`, `fix(deps):`, or `Update *digest*`
- Pure version bumps with no structural changes

### Step 3: Fetch PR Details

For each remaining PR, fetch the diff or changed files:

```bash
gh pr view <number> --repo onedr0p/home-ops --json files,body,title,url
```

For particularly interesting PRs, get the full diff:

```bash
gh pr diff <number> --repo onedr0p/home-ops
```

### Step 4: Analyze and Categorize

Categorize changes into:

| Category | What to Look For |
|----------|-----------------|
| **New Apps** | New directories under `kubernetes/apps/` |
| **Architecture** | Changes to flux config, components, networking, storage |
| **Patterns** | New reusable components, Kustomize overlays, Helm patterns |
| **Infrastructure** | Talos config changes, Cilium, CSI, DNS |
| **Observability** | New dashboards, alerting rules, log pipelines |
| **Security** | Auth changes, network policies, secret management |

### Step 5: Assess Relevance

For each interesting change, evaluate against our repo:

1. **Do we already have this?** Check if we have an equivalent in `/opt/home-ops/`
2. **Is it applicable?** Consider our infrastructure differences (TrueNAS, Talos, etc.)
3. **Effort vs value?** Quick win or major refactor?

### Step 6: Present Findings

Format the report as:

```markdown
# Upstream Scout Report: onedr0p/home-ops
**Period**: [start] to [end]
**PRs reviewed**: N (M total merged, K Renovate excluded)

## Highlights

### [Category]: [Brief Title]
**PR**: [#number](url) — [title]
**What**: One-line summary of the change
**Why it's interesting**: Why this matters for our setup
**Adoption effort**: Low / Medium / High
**Relevant files**: Key paths in their repo

---

## Already Have / Not Applicable
- PR #X: [title] — [reason skipped]

## Summary
[2-3 sentence takeaway of the most impactful findings]
```

## Tips

- If the time period yields zero interesting results, say so clearly rather than padding the report.
- When fetching diffs, focus on structural changes (new files, new directories) over inline edits.
- Cross-reference with our repo's `kubernetes/apps/` to quickly identify new apps we don't have.
- Look at their `kubernetes/components/` for reusable patterns.
- Pay attention to changes in gateway/ingress configuration since we use the same Envoy Gateway + Gateway API stack.
