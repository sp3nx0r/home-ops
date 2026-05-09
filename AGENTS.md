# AGENTS.md

This is a GitOps mono-repo for a bare-metal Kubernetes homelab ("Securimancy Homelab").

## Documentation

The `docs/` directory contains architecture decisions, implementation plans, and operational runbooks authored by the repo owner. Always check `docs/` for prior context before proposing changes — a plan or runbook may already exist for what you're about to do.

- `docs/backup-and-recovery/` — backup strategy, disaster recovery, and restore runbooks (Volsync, B2, ZFS)
- `docs/completed/` — finished plans kept for historical reference
- Top-level docs — active plans and investigations

When creating implementation plans or runbooks, add them to `docs/`. Move plans to `docs/completed/` once fully implemented.

## Repository Layout

```
kubernetes/           Flux GitOps manifests (the primary workload)
  apps/               App deployments, organized by namespace
  components/         Reusable Kustomize Components (sops, volsync)
  flux/               Flux system bootstrap (cluster Kustomization)
ansible/              Ansible playbooks and inventory (TrueNAS, infrastructure)
talos/                Talos Linux node configs (talhelper)
scripts/              Helper scripts (bootstrap, pre-commit hooks)
.taskfiles/           Task runner definitions (ansible, kubernetes, talos, volsync)
.github/workflows/    CI — flux-local validation, label sync
docs/                 Plans, runbooks, and architecture docs
```

## Kubernetes / Flux Patterns

### App Structure

Every app follows this directory convention:

```
kubernetes/apps/<namespace>/<app-name>/
  ks.yaml                    Flux Kustomization — points to ./app, sets postBuild vars
  app/
    kustomization.yaml       Kustomize manifest list, may reference ../../components/*
    helmrelease.yaml         HelmRelease (Flux v2 API: helm.toolkit.fluxcd.io/v2)
    ocirepository.yaml       OCI source for the Helm chart
    secret.sops.yaml         SOPS-encrypted Secret (optional)
    volsync-secret.sops.yaml Volsync repo credentials (optional, for apps with backups)
    pvc.yaml                 PersistentVolumeClaim (optional)
```

### Key conventions

- **Helm charts**: Most apps use the `bjw-s-labs/app-template` chart via OCI (`oci://ghcr.io/bjw-s-labs/helm/app-template`). The HelmRelease references a sibling `OCIRepository` by name, not an inline chart spec.
- **Schema comments**: YAML files include `# yaml-language-server: $schema=...` on the first line for editor validation. Preserve these.
- **Variable substitution**: `ks.yaml` files use `spec.postBuild.substitute` and `substituteFrom` to inject variables like `${APP}`, `${VOLSYNC_CAPACITY}`, and cluster secrets (`${SECRET_DOMAIN}`, etc.) from the `cluster-secrets` Secret.
- **Namespace scoping**: Each namespace directory has a `namespace.yaml` and a `kustomization.yaml` that lists all app `ks.yaml` files and includes `../../components/sops`.
- **Dependencies**: Apps declare `dependsOn` in their `ks.yaml` when they need another app running first (e.g., volsync).
- **YAML anchors**: HelmRelease files use YAML anchors (e.g., `&port 32400` / `*port`) to avoid repeating port numbers.

### Namespaces

| Namespace        | Purpose                                                    |
|------------------|------------------------------------------------------------|
| `media`          | Media stack — Plex, Sonarr, Radarr, qBittorrent, etc.     |
| `network`        | Ingress, DNS, tunnels — Envoy Gateway, Cloudflare, CoreDNS |
| `o11y`           | Observability — Grafana, Loki, Prometheus, Vector          |
| `security`       | Auth — Pocket ID (OIDC)                                    |
| `storage`        | Distributed storage — Garage (S3)                          |
| `cert-manager`   | TLS certificate automation                                 |
| `external-secrets` | External secret management                               |
| `kube-system`    | Core cluster services — Cilium, CoreDNS, metrics-server    |
| `flux-system`    | Flux controllers and bootstrap                             |
| `volsync-system` | Volsync backup operator                                    |
| `default`        | Misc tools — IT-Tools, Ollama, SearXNG, OpenWebUI          |

### Reusable Components

`kubernetes/components/` holds Kustomize Components shared across apps:

- **`sops/`** — Includes the encrypted `cluster-secrets.sops.yaml` Secret. Referenced by every namespace's `kustomization.yaml`.
- **`volsync/`** — Templated `ReplicationSource` and `ReplicationDestination` for Kopia-based PVC backups. Apps opt in by including this component and setting `${APP}`, `${VOLSYNC_CAPACITY}`, etc. via their `ks.yaml`.

### Ingress and Routing

- **Gateway API** via Envoy Gateway, not legacy Ingress resources.
- HelmRelease values use `route:` (from app-template) with `parentRefs` pointing to gateway names in the `network` namespace.
- Gatus health checks are configured via annotations: `gatus.home-operations.com/endpoint`.
- LoadBalancer IPs are assigned via Cilium L2 announcements: `lbipam.cilium.io/ips` annotation.

## Secrets and Encryption

- **SOPS + age** for secret encryption. The age key is at `age.key` (repo root).
- Files matching `*.sops.yaml` or `*.sops.yml` MUST be encrypted. A pre-commit hook (`scripts/pre-commit-check-sops.sh`) enforces this.
- **Never commit plaintext secrets.** If you create or modify a `*.sops.yaml` file, encrypt it with `sops --encrypt --in-place <file>`.
- `.sops.yaml` at the repo root defines encryption rules per path:
  - `kubernetes/**` and `bootstrap/**` — encrypts only `data` and `stringData` fields
  - `talos/**` and `ansible/**` — encrypts the entire file (`mac_only_encrypted`)
- A TruffleHog pre-commit hook scans for leaked secrets on every commit.

## Talos Linux

- Three bare-metal control-plane nodes: `miirym`, `palarandusk`, `aurinax` (192.168.5.50-52)
- Hyper-converged: all nodes run workloads (no dedicated workers)
- VIP at `192.168.5.254` for the API server
- Configured via **talhelper** — `talos/talconfig.yaml` is the source of truth
- Generated configs land in `talos/clusterconfig/`
- Global patches in `talos/patches/global/`, controller patches in `talos/patches/controller/`
- Secure Boot enabled, TPM-based disk encryption (LUKS2)

## Infrastructure

- **NAS**: TrueNAS SCALE at `192.168.5.40`, NFS exports under `/mnt/tank/`
  - Media: `/mnt/tank/media`
  - App configs: `/mnt/tank/homelab/k8s-exports/<app>-config`
  - Kopia repo: `/mnt/tank/homelab/kopia`
- **CNI**: Cilium (eBPF, kube-proxy replacement, L2 announcements)
- **Storage classes**: `iscsi` for PVCs backed by Democratic-CSI
- **DNS**: Two external-dns instances (Cloudflare public + UniFi private)
- **Backups**: Volsync with Kopia to NFS, Backblaze B2 for offsite

## Tooling

Tools are version-pinned in `.mise.toml` and installed via mise (aqua backend). Key tools:

- `task` — Task runner (see `Taskfile.yaml`, `.taskfiles/`)
- `flux` — Flux CLI for GitOps operations
- `kubectl` / `helm` / `kustomize` — Kubernetes management
- `talosctl` / `talhelper` — Talos node management
- `sops` / `age` — Secret encryption
- `kubeconform` — YAML schema validation

Run `task` (no args) to list available commands. Common tasks:
- `task reconcile` — Force Flux to pull latest changes
- `task talos:*` — Talos node operations
- `task volsync:*` — Backup/restore operations

## Style and Conventions

- All Kubernetes manifests are YAML with `---` document separators.
- Use 2-space indentation for YAML.
- Image tags should include the SHA256 digest (`tag@sha256:...`) for reproducibility.
- Renovate manages dependency updates (`.renovaterc.json5`).
- Keep HelmRelease values minimal — only override what differs from chart defaults.
- Security contexts: prefer `runAsNonRoot`, `readOnlyRootFilesystem`, and drop all capabilities.
