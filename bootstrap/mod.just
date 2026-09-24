set no-exit-message
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

[doc('Bootstrap the Talos cluster (topf secrets/apply/config)')]
[group('bootstrap')]
talos: talos-secret talos-apply talos-talosconfig talos-kubeconfig
    just log info "Talos cluster bootstrapped"

# The secrets bundle is stored already encrypted with the repo's age
# recipient; existing bundles are left untouched.
[private]
[working-directory('../talos')]
talos-secret:
    just log info "Generating secrets" stage "{{ recipe_name() }}"
    topf secrets --confirm=false > /dev/null

[private]
[working-directory('../talos')]
talos-apply:
    just log info "Applying Talos config and bootstrapping" stage "{{ recipe_name() }}"
    topf apply --auto-bootstrap --confirm=false

[private]
[working-directory('../talos')]
talos-talosconfig:
    just log info "Generating talosconfig" stage "{{ recipe_name() }}"
    mkdir -p clusterconfig
    topf talosconfig > clusterconfig/talosconfig

# topf issues short-lived admin certs by default; 8760h keeps the kubeconfig
# usable long-term.
[private]
[working-directory('../talos')]
talos-kubeconfig:
    just log info "Fetching kubeconfig" stage "{{ recipe_name() }}"
    topf kubeconfig --validity 8760h > "{{ justfile_directory() }}/../kubeconfig"

# Apps bootstrap stays script-based for now; the helmfile approach is Phase 3
# of the cluster-template alignment plan.
[doc('Bootstrap apps into the Talos cluster')]
[group('bootstrap')]
apps:
    just log info "Bootstrapping apps"
    bash "{{ justfile_directory() }}/../scripts/bootstrap-apps.sh"
