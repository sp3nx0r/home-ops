set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

alpine := "docker.io/library/alpine:3.24.1@sha256:79ff19e9084a00eece421b2523fb93e22d730e2c0e525905de047e848e56d95f"

[doc('Force Flux to pull in changes from your Git repository')]
[group('kube')]
reconcile:
    flux --namespace flux-system reconcile kustomization flux-system --with-source

[doc('Mount a PVC to a temp container [claim=required] [ns=default]')]
[group('kube')]
browse-pvc claim ns='default':
    kubectl run -n "{{ ns }}" "browse-pvc-{{ claim }}" -it --rm --restart=Never \
        --image="{{ alpine }}" \
        --overrides='{"spec":{"containers":[{"name":"browse-pvc-{{ claim }}","image":"{{ alpine }}","stdin":true,"tty":true,"command":["/bin/sh"],"workingDir":"/mnt","volumeMounts":[{"mountPath":"/mnt","name":"data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"{{ claim }}"}}]}}'

[doc('Open a root debug shell on a node [node=required]')]
[group('kube')]
debug-node node:
    trap 'kubectl delete pod -n default -l app.kubernetes.io/managed-by=kubectl-debug --field-selector spec.nodeName={{ node }} --ignore-not-found --wait=false' EXIT
    kubectl debug node/{{ node }} -n default -it --image="{{ alpine }}" --profile=sysadmin

[arg('resource', pattern='hr|ks|gitrepo|ocirepo|es')]
[doc('Force-reconcile Flux resources or ExternalSecrets [resource=hr|ks|gitrepo|ocirepo|es]')]
[group('kube')]
sync resource:
    kubectl get {{ resource }} --all-namespaces --no-headers | while read -r ns name _; do
        kubectl --namespace "$ns" annotate --field-manager flux-client-side-apply --overwrite {{ resource }} "$name" \
            "force-sync=$(date +%s)" \
            "reconcile.fluxcd.io/requestedAt=$(date +%s)" \
            "reconcile.fluxcd.io/forceAt=$(date +%s)"
    done

[doc('Delete pods in a Failed/Pending/Succeeded phase')]
[group('kube')]
cleanse-pods:
    for phase in Failed Pending Succeeded; do
        kubectl delete pods --all-namespaces \
            --field-selector "status.phase=$phase" --ignore-not-found=true
    done
