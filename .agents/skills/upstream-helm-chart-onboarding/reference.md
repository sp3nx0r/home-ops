# Onboarding reference

## Idempotent bootstrap Job (API-only settings)

- Put it in a second Kustomization in the same `ks.yaml`, with `dependsOn` the app Kustomization and `wait: true` on the app. Pattern: `kubernetes/apps/system-upgrade/tuppr/ks.yaml`.
- Generate the script ConfigMap with `configMapGenerator`. The content hash changes the Job spec whenever the script changes.
- Annotate the Job `kustomize.toolkit.fluxcd.io/force: enabled`, so Flux replaces the immutable Job instead of failing.
- **Leave out `ttlSecondsAfterFinished`.** Otherwise the Job disappears and Flux recreates and re-runs it on every reconcile.
- Image: `python:<ver>-alpine`, digest-pinned, stdlib only (`urllib`, `json`). Run as 65534 with a read-only root FS and `PYTHONDONTWRITEBYTECODE=1`.
- GET before every POST/PUT, and guard `null` sub-objects (`(resp.get("schedule") or {})`).
- Check request shapes against upstream swagger at the pinned tag: `gh api "repos/<org>/<repo>/contents/<swagger path>?ref=<tag>" --jq .content | base64 -d`.
- The Job pod needs its own CNP: egress to the app's API port; ingress none.

## Manual Volsync restore for vendor charts

`just volsync restore <app> <previous> <ns>` reads `.spec.values.controllers.<app>.type` and scales `<controller>/<app>`, which only works for app-template. Document this instead:

1. `flux suspend ks <app> -n <ns>` and `flux suspend hr <app> -n <ns>`.
2. Scale the chart's workloads to 0 (`kubectl -n <ns> scale deploy,sts -l app.kubernetes.io/instance=<app> --replicas=0`).
3. Render `volsync/resources/replicationdestination.tmpl.yaml` with `NS`, `APP`, `PREVIOUS`, `CLAIM`, `CAPACITY`, `PUID`, `PGID` (999 for Postgres) and apply it.
4. Wait for the restore to complete, then resume the HR and Kustomization.
5. A restored DB and its object store (Garage bucket) can be out of step. Say so in the app's doc.

General restore runbooks: `docs/backup-and-recovery/runbook-restore-pvc.md`.

## Secret generation without plaintext in the transcript

```sh
set -e; umask 077
PW=$(openssl rand -hex 24)
HT=$(docker run --rm docker.io/library/httpd:2.4-alpine htpasswd -nbB -C 10 <user> "$PW" | head -1)
PW="$PW" HT="$HT" yq -n '.apiVersion="v1" | .kind="Secret" | .metadata.name="<app>-values"
  | .stringData.password=strenv(PW) | .stringData.htpasswd=strenv(HT)' > secret.sops.yaml
sops --encrypt --in-place secret.sops.yaml && grep -c 'ENC\[' secret.sops.yaml
unset PW HT
```

Put literal values (like the domain) in the Secret rather than `${SECRET_DOMAIN}`; bcrypt `$2a$...` strings sit next to postBuild substitution there. If the owner must supply a value, use an inert placeholder and put the exact `sops set` command in the PR body.
