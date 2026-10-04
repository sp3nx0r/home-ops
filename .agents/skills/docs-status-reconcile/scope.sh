#!/usr/bin/env bash
# List docs that reference recent changes, ranked by hit count.
#
#   scope.sh                  non-Renovate commits on origin/main since the last commit touching docs/
#   scope.sh <rev>            ... since <rev> (SHA, tag, or e.g. 'origin/main@{3.days.ago}')
#   scope.sh --prs 591 593    files and numbers of these PRs (open or merged), e.g. this session's PRs
#
# Terms searched: app dir names (kubernetes/apps/<ns>/<app>), skill names
# (.agents/skills/<skill>), basenames of other changed files, and PR numbers (#N).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
git fetch -q origin

files=() prs=()
if [[ ${1:-} == --prs ]]; then
  shift
  for n in "$@"; do
    prs+=("#$n")
    mapfile -t -O "${#files[@]}" files < <(gh pr view "$n" --json files --jq '.files[].path')
  done
  echo "scope: PRs $*" >&2
else
  base=${1:-$(git log -1 --format=%H origin/main -- docs/)}
  range="$base..origin/main"
  author=(--perl-regexp '--author=^(?!renovate)')
  mapfile -t files < <(git log "${author[@]}" --name-only --format= "$range")
  mapfile -t prs < <(git log "${author[@]}" --format=%s "$range" | rg -o '#[0-9]+' || true)
  echo "scope: $(git log "${author[@]}" --oneline "$range" | wc -l) commits in $range" >&2
fi

generic="kustomization.yaml ks.yaml helmrelease.yaml namespace.yaml ocirepository.yaml config.yaml config.toml mod.just justfile SKILL.md reference.md README.md"
mapfile -t terms < <(
  {
    printf '%s\n' "${files[@]}" | rg -v '(^$|mise\.lock$)' |
      awk -F/ -v generic="$generic" '
        BEGIN { split(generic, g, " "); for (i in g) skip[g[i]] = 1 }
        $1=="kubernetes" && $2=="apps" { print (NF > 4 ? $4 : $3); next }
        $1=="kubernetes" && $2=="components" { print $3; next }
        $1==".agents" { print $3; next }
        { print $0; if (!($NF in skip)) print $NF }'
    printf '%s\n' "${prs[@]}"
  } | rg -v '^$' | sort -u
)

if ((${#terms[@]} == 0)); then
  echo "no non-Renovate changes in scope" >&2
  exit 0
fi
echo "terms: ${terms[*]}" >&2

args=()
for t in "${terms[@]}"; do args+=(-e "$t"); done
rg -c -w -F "${args[@]}" docs AGENTS.md --glob '!docs/completed/**' --glob '!docs/archived/**' |
  sort -t: -k2 -rn || echo "no docs reference these changes" >&2
