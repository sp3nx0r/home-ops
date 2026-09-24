set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list

[group('ansible')]
mod ansible 'ansible'

[group('bootstrap')]
mod bootstrap 'bootstrap'

[group('github')]
mod github 'github.just'

[group('kubernetes')]
mod kube 'kubernetes'

[group('talos')]
mod talos 'talos'

[group('volsync')]
mod volsync 'volsync'

# Structured logger used by other recipes (requires gum).
[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[doc('Force Flux to pull in changes from your Git repository')]
reconcile:
    just kube reconcile
