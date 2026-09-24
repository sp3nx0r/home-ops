set no-exit-message
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

# justfile_directory() resolves to the repo root; source_directory() to this
# bootstrap module dir.
kubernetes_dir := justfile_directory() / 'kubernetes'

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
    topf kubeconfig --validity 8760h > "{{ justfile_directory() }}/kubeconfig"

# Apps bootstrap seeds the minimal runtime (Cilium, CoreDNS, Spegel,
# cert-manager, Flux) via Helmfile, then hands off to Flux. Chart versions and
# values are read from kubernetes/apps/<ns>/<name>/app/, matching Flux.
[doc('Bootstrap apps into the Talos cluster')]
[group('bootstrap')]
apps: apps-ready apps-namespaces apps-secrets apps-crds apps-helm
    just log info "Cluster is bootstrapped — Flux will start syncing the Git repository"

# Nodes register as Ready=False first; they only flip to Ready=True once the CNI
# is healthy, which happens later in this bootstrap.
[private]
apps-ready:
    just log info "Waiting for nodes to register" stage "{{ recipe_name() }}"
    if ! kubectl wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; then
        deadline=$((SECONDS + 600))
        until kubectl wait nodes --for=condition=Ready=False --all --timeout=10s &>/dev/null; do
            if (( SECONDS >= deadline )); then
                just log fatal "Timed out waiting for nodes to register"
            fi
            just log info "Nodes not available yet, retrying in 5 seconds..."
            sleep 5
        done
    fi

[private]
apps-namespaces:
    just log info "Applying namespaces" stage "{{ recipe_name() }}"
    for app in "{{ kubernetes_dir }}/apps"/*/; do
        ns="$(basename "$app")"
        if kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply --server-side --filename - &>/dev/null; then
            just log info "Namespace applied" namespace "$ns"
        else
            just log fatal "Failed to apply namespace" namespace "$ns"
        fi
    done

# sops-age lets Flux decrypt SOPS manifests; cluster-secrets holds the shared
# substitution vars. The Git repo is public, so no deploy key is needed.
[private]
apps-secrets:
    just log info "Applying secrets" stage "{{ recipe_name() }}"
    for secret in \
        "{{ kubernetes_dir }}/apps/flux-system/flux-instance/app/sops-age.sops.yaml" \
        "{{ kubernetes_dir }}/components/sops/cluster-secrets.sops.yaml"
    do
        name="$(basename "$secret" .sops.yaml)"
        if sops decrypt "$secret" | kubectl --namespace flux-system apply --server-side --filename - &>/dev/null; then
            just log info "Secret applied" resource "$name"
        else
            just log fatal "Failed to apply secret" resource "$name"
        fi
    done

[private]
apps-crds:
    just log info "Applying CRDs" stage "{{ recipe_name() }}"
    if ! helmfile --file "{{ source_directory() }}/helmfile/crds.yaml" template --quiet | yq eval-all --exit-status 'select(.kind == "CustomResourceDefinition")' | kubectl apply --server-side --force-conflicts --filename -; then
        just log fatal "Failed to apply CRDs"
    fi

[private]
apps-helm:
    just log info "Syncing Helm releases" stage "{{ recipe_name() }}"
    if ! helmfile --file "{{ source_directory() }}/helmfile/apps.yaml" sync --hide-notes; then
        just log fatal "Failed to sync Helm releases"
    fi
