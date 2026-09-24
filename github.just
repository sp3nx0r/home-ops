set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

[doc('Approve and squash-merge one or more PRs [prs=comma-separated numbers]')]
[group('github')]
merge prs:
    IFS=',' read -ra list <<< "{{ prs }}"
    for pr in "${list[@]}"; do
        gh pr review "$pr" --approve
        gh pr merge "$pr" --squash --delete-branch \
            || gh pr merge "$pr" --squash --delete-branch --auto
    done
