# Kasm Workspaces

Browser-based virtual desktops and applications via container streaming.

## Prerequisites

Before deploying Kasm Workspaces:

1. **csi-driver-nfs** — Needed for dynamic PVCs (PostgreSQL database storage).
   Set up a StorageClass backed by NFS on the NAS (`192.168.5.40`).

2. **Kasm Agent** — Required to run containerized desktop sessions.
   Must run on a VM or bare-metal host (not Talos nodes, which are immutable).
   Options: a VM on the NAS, a dedicated box, or a cloud instance.

3. **TLS Certificate** — Use cert-manager with the existing Let's Encrypt/Cloudflare setup.

## Helm Chart

Kasm uses its own Helm chart (not app-template):
- Repo: https://github.com/kasmtech/kasm-helm
- Branch: `release/1.18.1` (latest as of Apr 2026)
- Status: **Technical preview** — suitable for demo/evaluation

## Architecture

The chart deploys multiple services:
- **kasm-api** — REST API server
- **kasm-manager** — Session orchestration
- **kasm-proxy** — Connection proxy for sessions
- **PostgreSQL** — Metadata database (needs PVC)

The agent (installed separately) handles the actual container sessions.

## Install Steps (when ready)

```bash
helm install kasm ./charts/kasm \
  --namespace default \
  --set publicAddr="kasm.securimancy.com" \
  --set certificate.secretName="<cert-secret>"
```

## Default Credentials

- Admin: `admin@kasm.local` (password in k8s secret)
- User: `user@kasm.local` (password in k8s secret)

## TODO

- [ ] Set up csi-driver-nfs + StorageClass
- [ ] Decide on Kasm Agent host
- [ ] Create HelmRelease + Flux Kustomization
- [ ] Configure HTTPRoute on envoy-internal
