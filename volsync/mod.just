set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

# VolSync snapshot/restore operations. Assumes each app's Flux Kustomization,
# HelmRelease, PVC, and ReplicationSource share a name; Kopia repository; one
# replicated PVC per app.

[arg('action', pattern='suspend|resume')]
[doc('Suspend or resume VolSync [action=suspend|resume]')]
[group('volsync')]
state action:
    flux --namespace volsync-system {{ action }} kustomization volsync
    flux --namespace volsync-system {{ action }} helmrelease volsync
    kubectl --namespace volsync-system scale deployment volsync \
        --replicas {{ if action == "suspend" { "0" } else { "1" } }}

[doc('List all ReplicationSources and their last sync time')]
[group('volsync')]
list:
    kubectl get replicationsources --all-namespaces \
        -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,LAST_SYNC:.status.lastSyncTime,NEXT_SYNC:.status.nextSyncTime'

[doc('Trigger a manual snapshot [app=required] [ns=default]')]
[group('volsync')]
snapshot app ns='default':
    kubectl --namespace "{{ ns }}" patch "replicationsources/{{ app }}" --type merge \
        -p "{\"spec\":{\"trigger\":{\"manual\":\"$(date +%s)\"}}}"
    until kubectl --namespace "{{ ns }}" get "job/volsync-src-{{ app }}" &>/dev/null; do sleep 5; done
    kubectl --namespace "{{ ns }}" wait "job/volsync-src-{{ app }}" --for=condition=complete --timeout=120m

[confirm("This scales the VolSync controller to 0, deletes the source job/temp PVC/snapshot/cache for the app, restores the controller, and triggers a fresh run. The live app PVC is untouched. Continue? [y/N]")]
[doc('Reset a failed VolSync source backup and trigger a fresh run [app=required] [ns=default]')]
[group('volsync')]
[working-directory('../ansible')]
reset-source app ns='default':
    .venv/bin/ansible-playbook playbooks/volsync-reset-source.yml \
        --extra-vars "target_namespace={{ ns }} app={{ app }}"

[doc('Restore an app from backup [app=required] [previous=required] [ns=default]')]
[group('volsync')]
restore app previous ns='default':
    export NS="{{ ns }}" APP="{{ app }}" PREVIOUS="{{ previous }}"
    export CLAIM="$(kubectl --namespace "$NS" get "replicationsources/$APP" --output=jsonpath='{.spec.sourcePVC}')"
    export CAPACITY="$(kubectl --namespace "$NS" get "replicationsources/$APP" --output=jsonpath='{.spec.kopia.cacheCapacity}')"
    export PUID="$(kubectl --namespace "$NS" get "replicationsources/$APP" --output=jsonpath='{.spec.kopia.moverSecurityContext.runAsUser}')"
    export PGID="$(kubectl --namespace "$NS" get "replicationsources/$APP" --output=jsonpath='{.spec.kopia.moverSecurityContext.runAsGroup}')"
    controller="$(kubectl --namespace "$NS" get "helmrelease/$APP" --output=jsonpath="{.spec.values.controllers.$APP.type}")"
    controller="${controller:-deployment}"
    # Suspend
    flux --namespace "$NS" suspend kustomization "$APP"
    flux --namespace "$NS" suspend helmrelease "$APP"
    kubectl --namespace "$NS" scale "$controller/$APP" --replicas 0
    kubectl --namespace "$NS" wait pod --for=delete --selector="app.kubernetes.io/name=$APP" --timeout=5m
    # Restore
    envsubst < resources/replicationdestination.tmpl.yaml | kubectl apply --server-side --filename -
    until kubectl --namespace "$NS" get "job/volsync-dst-$APP-manual" &>/dev/null; do sleep 5; done
    kubectl --namespace "$NS" wait "job/volsync-dst-$APP-manual" --for=condition=complete --timeout=120m
    kubectl --namespace "$NS" delete replicationdestination "$APP-manual"
    # Resume
    flux --namespace "$NS" resume kustomization "$APP"
    flux --namespace "$NS" resume helmrelease "$APP"
    flux --namespace "$NS" reconcile helmrelease "$APP" --force
    kubectl --namespace "$NS" wait pod --for=condition=ready --selector="app.kubernetes.io/name=$APP" --timeout=5m
