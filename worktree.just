set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

# Root of the primary checkout; worktrees are created as siblings.
root := justfile_directory()

[doc('Create a worktree for agent work [name=required] [type=feat]')]
[group('worktree')]
new name type='feat':
    branch="{{ type }}/{{ name }}"
    path="{{ root }}/../home-ops-{{ name }}"
    git -C "{{ root }}" fetch origin
    git -C "{{ root }}" worktree add -b "$branch" "$path" origin/main
    abs="$(cd "$path" && pwd)"
    gum log -t rfc3339 -s -l info "Created worktree" branch "$branch" path "$abs"
    gum log -t rfc3339 -s -l info "Next" cd "$abs"

[doc('List all worktrees')]
[group('worktree')]
list:
    git -C "{{ root }}" worktree list

[doc('Remove a single worktree and prune [name=required]')]
[group('worktree')]
remove name:
    git -C "{{ root }}" worktree remove "{{ root }}/../home-ops-{{ name }}"
    git -C "{{ root }}" worktree prune
    gum log -t rfc3339 -s -l info "Removed worktree" name "{{ name }}"

[doc('Remove ALL non-primary worktrees (periodic cleanup)')]
[group('worktree')]
nuke:
    main="$(git -C "{{ root }}" rev-parse --path-format=absolute --git-common-dir | xargs dirname)"
    mapfile -t paths < <(git -C "{{ root }}" worktree list --porcelain | awk '/^worktree /{print $2}')
    targets=()
    for p in "${paths[@]}"; do
        [[ "$p" == "$main" ]] && continue
        targets+=("$p")
    done
    if [[ "${#targets[@]}" -eq 0 ]]; then
        gum log -t rfc3339 -s -l info "No worktrees to remove"
        exit 0
    fi
    printf '%s\n' "${targets[@]}"
    gum confirm "Remove the ${#targets[@]} worktree(s) above? Uncommitted changes in them will be lost."
    for p in "${targets[@]}"; do
        git -C "{{ root }}" worktree remove --force "$p"
        gum log -t rfc3339 -s -l info "Removed worktree" path "$p"
    done
    git -C "{{ root }}" worktree prune
    gum log -t rfc3339 -s -l info "Worktree cleanup complete"
