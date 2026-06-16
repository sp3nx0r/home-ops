# SillyTavern Deployment Plan

## Goal

Deploy SillyTavern into the Kubernetes cluster with persistent storage, internal web access for friends on the trusted network, and connectivity to the existing ms-s1 Ollama server through `ollama-proxy`.

## Design

- Run SillyTavern in the `default` namespace using the existing Flux and bjw-s-labs `app-template` pattern.
- Expose the UI at `https://tavern.${SECRET_DOMAIN}` through `envoy-internal`.
- Use the pinned container image `ghcr.io/sillytavern/sillytavern:1.18.0@sha256:7b30a1698b605d01dbd01a20459600c035f0d2c866912b69d7eee98065dcedd3`.
- Persist SillyTavern state on a single 20Gi iSCSI PVC named `sillytavern`.
- Back up the PVC with the shared Volsync/Kopia component.
- Do not add Pocket ID or SillyTavern auth for the first deployment. Access is limited by the internal route.

## Kubernetes Changes

- Add `kubernetes/apps/default/sillytavern/ks.yaml`.
- Add app manifests under `kubernetes/apps/default/sillytavern/app/`:
  - `helmrelease.yaml`
  - `ocirepository.yaml`
  - `pvc.yaml`
  - `volsync-secret.sops.yaml`
  - `kustomization.yaml`
- Register the app in `kubernetes/apps/default/kustomization.yaml`.

## Runtime Configuration

SillyTavern listens on port `8000` with:

- `SILLYTAVERN_LISTEN=true`
- `SILLYTAVERN_PORT=8000`
- `SILLYTAVERN_WHITELISTMODE=false`
- `SILLYTAVERN_HEARTBEATINTERVAL=30`
- `PUID=1000`
- `PGID=1000`
- `TZ=America/Chicago`

The 20Gi PVC is mounted with subPaths:

- `/home/node/app/config` -> `config`
- `/home/node/app/data` -> `data`
- `/home/node/app/plugins` -> `plugins`
- `/home/node/app/public/scripts/extensions/third-party` -> `extensions`

Liveness and readiness probes run `node src/healthcheck.js`.

## Ollama Setup

After deployment:

1. Open `https://tavern.${SECRET_DOMAIN}` from the trusted network.
2. Configure the API connection in the SillyTavern UI to use Ollama or OpenAI-compatible mode.
3. Use `https://ollama.${SECRET_DOMAIN}` as the Ollama/OpenAI-compatible base URL.

The existing `ollama-proxy` HTTPRoute injects `Authorization: Bearer ${SECRET_OLLAMA_API_KEY}` before forwarding traffic to ms-s1, so SillyTavern does not need to store the Ollama bearer token.

## Validation

Before merge or apply:

```bash
kustomize build kubernetes/apps/default
flux-local test --enable-helm --all-namespaces --path kubernetes/flux/cluster -v
```

After Flux reconciles:

```bash
kubectl -n default get kustomization sillytavern
kubectl -n default get pod,pvc,httproute sillytavern
kubectl -n default get replicationsource,replicationdestination | grep sillytavern
```

Then verify `https://tavern.${SECRET_DOMAIN}` loads and SillyTavern can list Ollama models through `https://ollama.${SECRET_DOMAIN}`.
