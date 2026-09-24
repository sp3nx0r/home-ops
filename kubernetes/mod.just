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

[doc('Open a shell to a node [node=required] [ns=kube-system]')]
[group('kube')]
node-shell node ns='kube-system':
    kubectl node-shell -n "{{ ns }}" -x "{{ node }}"

[doc('Force-sync all ExternalSecrets')]
[group('kube')]
sync-secrets:
    kubectl get externalsecret --all-namespaces --no-headers \
        --output=jsonpath='{range .items[*]}{.metadata.namespace},{.metadata.name}{"\n"}{end}' \
    | while IFS=, read -r ns name; do
        [[ -z "$ns" ]] && continue
        kubectl --namespace "$ns" annotate externalsecret "$name" \
            "force-sync=$(date +%s)" --overwrite
      done

[doc('Delete pods in a Failed/Pending/Succeeded phase')]
[group('kube')]
cleanse-pods:
    for phase in Failed Pending Succeeded; do
        kubectl delete pods --all-namespaces \
            --field-selector "status.phase=$phase" --ignore-not-found=true
    done
