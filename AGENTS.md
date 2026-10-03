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
talos/                Talos Linux node configs (topf)
scripts/              Helper scripts (SOPS pre-commit hook)
justfile              Task runner entrypoint; per-area recipes live in <area>/mod.just
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
    ciliumnetworkpolicy.yaml CiliumNetworkPolicy allow-list (required — see Network Policy)
```

### Key conventions

- **Helm charts**: Most apps use the `bjw-s-labs/app-template` chart via OCI (`oci://ghcr.io/bjw-s-labs/helm/app-template`). The HelmRelease references a sibling `OCIRepository` by name, not an inline chart spec.
- **Schema comments**: YAML files include `# yaml-language-server: $schema=...` on the first line for editor validation. Preserve these.
- **Variable substitution**: `ks.yaml` files use `spec.postBuild.substitute` and `substituteFrom` to inject variables like `${APP}`, `${VOLSYNC_CAPACITY}`, and cluster secrets (`${SECRET_DOMAIN}`, etc.) from the `cluster-secrets` Secret.
- **Namespace scoping**: Each namespace directory has a `namespace.yaml` and a `kustomization.yaml` that lists all app `ks.yaml` files and includes `../../components/sops`.
- **Pod Security labels**: every `namespace.yaml` must set `pod-security.kubernetes.io/enforce` (`baseline` by default; `privileged` only where required, e.g. `kube-system`, `download`, `kubescape`, `system-upgrade`). A Kyverno `ValidatingPolicy` in `Deny` mode rejects namespaces without it (exempt: `kube-*`, `flux-system`, `kyverno`, `cilium-secrets`).
- **Dependencies**: Apps declare `dependsOn` in their `ks.yaml` when they need another app running first (e.g., volsync).
- **YAML anchors**: HelmRelease files use YAML anchors (e.g., `&port 32400` / `*port`) to avoid repeating port numbers.

### Namespaces

| Namespace          | Purpose                                                                                 |
| ------------------ | --------------------------------------------------------------------------------------- |
| `media`            | Media stack — Plex, Sonarr, Radarr, qBittorrent, etc.                                   |
| `download`         | VPN torrent client — qbittorrent-gluetun (PSA `privileged` for the gluetun sidecar)     |
| `archive`          | ArchiveTeam Warrior                                                                     |
| `system-upgrade`   | Tuppr — Talos/Kubernetes upgrades (PSA `privileged`, Talos `os:admin` API access)       |
| `network`          | Ingress, DNS, tunnels — Envoy Gateway, Cloudflare, CoreDNS                              |
| `o11y`             | Observability — Grafana, Loki, Prometheus, Kromgo, Vector                               |
| `security`         | Auth — Pocket ID (OIDC)                                                                 |
| `kubescape`        | Posture + vulnerability scanning — Kubescape Operator (PSA `privileged` for node-agent) |
| `kyverno`          | Admission policy — Kyverno controllers + CEL `ValidatingPolicy` set (`policies/`)       |
| `storage`          | Distributed storage — Garage (S3)                                                       |
| `cert-manager`     | TLS certificate automation                                                              |
| `external-secrets` | External secret management                                                              |
| `kube-system`      | Core cluster services — Cilium, CoreDNS, metrics-server                                 |
| `flux-system`      | Flux controllers and bootstrap                                                          |
| `volsync-system`   | Volsync backup operator                                                                 |
| `default`          | Misc tools — IT-Tools, Ollama, SearXNG, OpenWebUI                                       |

### Reusable Components

`kubernetes/components/` holds Kustomize Components shared across apps:

- **`sops/`** — Includes the encrypted `cluster-secrets.sops.yaml` Secret. Referenced by every namespace's `kustomization.yaml`.
- **`volsync/`** — Templated `ReplicationSource` and `ReplicationDestination` for Kopia-based PVC backups. Apps opt in by including this component and setting `${APP}`, `${VOLSYNC_CAPACITY}`, etc. via their `ks.yaml`.

### Ingress and Routing

- **Gateway API** via Envoy Gateway, not legacy Ingress resources.
- HelmRelease values use `route:` (from app-template) with `parentRefs` pointing to gateway names in the `network` namespace.
- Gatus health checks are configured via annotations: `gatus.home-operations.com/endpoint`.
- **`envoy-external` + Gatus**: Cloudflare external-dns publishes public records automatically, but UniFi private DNS only syncs `envoy-internal` routes. Gatus probes from inside the cluster, so each new external hostname also needs a UniFi CNAME in `kubernetes/apps/network/unifi-dns/app/dnsendpoint.yaml` (typically to `external.${SECRET_DOMAIN}`).
- LoadBalancer IPs are assigned via Cilium L2 announcements: `lbipam.cilium.io/ips` annotation.

### Network Policy (Cilium default-deny)

The cluster is **default-deny**. Two `CiliumClusterwideNetworkPolicy` (CCNP) resources, `default-deny-ingress` and `default-deny-egress` in `kubernetes/apps/kube-system/network-policies/`, select every pod outside `kube-system`. They allow only:

- **egress**: cluster DNS (kube-dns `:53`, L7 DNS rule);
- **ingress**: from the `host`, `remote-node`, `kube-apiserver` and `health` entities on all ports (kubelet probes, cilium-health, apiserver → webhooks).

Everything else must be allowed by a per-app `CiliumNetworkPolicy` (CNP) in `app/ciliumnetworkpolicy.yaml`. History and design: `docs/completed/cluster-default-deny-floor.md`.

Rules when adding or changing an app:

- **Ship the CNP in the same PR as the app or namespace.** A pod without one comes up isolated. It typically hangs at API-client init, fails its startup probes, or times out a Helm install with no obvious error in its logs (this is what happened to Kyverno, #524 → #563).
- **Common allow rules** (copy from existing CNPs, e.g. `system-upgrade/tuppr`, `kyverno/kyverno`):
    - Kubernetes API: `toEntities: [kube-apiserver]` on `6443`. Not in the floor; every operator/controller/Job that talks to Kubernetes needs it.
    - Prometheus scrape: `fromEndpoints` `io.kubernetes.pod.namespace: o11y` + `app.kubernetes.io/name: prometheus` on the metrics port.
    - Gateway traffic: `fromEndpoints` `io.kubernetes.pod.namespace: network` + `gateway.envoyproxy.io/owning-gateway-name: envoy-internal` (or `envoy-external`) on the container port, matching the route's `parentRefs`.
    - Admission webhooks: covered by the floor's ingress, but restate `fromEntities: [kube-apiserver, host, remote-node]` on the webhook port. The apiserver is host-networked, so it shows up as `host`/`remote-node`, not only `kube-apiserver`.
    - Internet egress: prefer `toFQDNs` for known hosts. Otherwise use `toCIDRSet: 0.0.0.0/0` with `except` for `10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10` rather than `toEntities: world` (which includes the LAN).
- **`toFQDNs` needs `ndots: 1`** on the pod (`dnsConfig.options`, or a postRenderer if the chart lacks it). CoreDNS `autopath` otherwise makes the FQDN never match, and traffic drops to a bare `world` IP.
- Namespace-wide CNPs (`endpointSelector` on `io.kubernetes.pod.namespace`) are fine for single-purpose namespaces whose Jobs/hooks share the same needs (e.g. `kyverno`, `system-upgrade`).
- `kube-system` is outside the floor; host-networked pods there (cilium, node-exporter, vector agent, spegel) aren't governed by CNPs.

Troubleshooting a pod that can't connect (check policy first, before app config):

```sh
# Live drops cluster-wide via Hubble Relay
cilium hubble port-forward &
hubble observe --verdict DROPPED --namespace <ns> --follow
# Without the CLI: exec into each cilium agent (each one only sees its own node)
for p in $(kubectl -n kube-system get pod -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$p" -c cilium-agent -- hubble observe --verdict DROPPED --namespace <ns> --last 20 -o compact
done
```

- Historical drops: Loki `{source="hubble"}` (labels `src_namespace`, `dst_namespace`, `direction`) and the Grafana **Network → Hubble Policy Drops** dashboard.
- Alert `HubblePolicyDenied` fires on a sustained non-ICMP drop. Known exclusions and expected drops (qbittorrent ICMP, Plex NAT-PMP, kubescape egress) are listed in the floor runbook.
- Confirm a pod is policy-enforced: `kubectl -n kube-system exec <cilium-pod> -c cilium-agent -- cilium-dbg endpoint list`.
- Emergency rollback of one direction: `kubectl delete ccnp default-deny-egress` (or `-ingress`). Flux restores it on the next reconcile.

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
- Configured via **topf** — `talos/topf.yaml` is the source of truth
- Generated configs land in `talos/clusterconfig/`
- Machine patches live in `talos/all/` (all nodes) and `talos/control-plane/` (control-plane nodes); `.tpl` patches are Go-templated by topf
- Secure Boot enabled, TPM-based disk encryption (LUKS2)
- **Reboots: always `talosctl reboot --mode powercycle`.** The default kexec reboot hangs before `apid` on this hardware (node pingable but `talosctl`/kube-api refused).

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

Tools are version-pinned in `.mise/config.toml` (with a checksum lockfile at `.mise/mise.lock`) and installed via mise. Key tools:

- `just` — Task runner (root `justfile` + per-area `<area>/mod.just` modules)
- `lefthook` — Git hook manager (`.lefthook.toml`); `mise` installs the hooks on `postinstall`
- `flux` — Flux CLI for GitOps operations
- `kubectl` / `helm` / `kustomize` — Kubernetes management. mise sets `KUBECONFIG` to `./kubeconfig` (repo root), so run cluster commands from inside the repo. Outside it, `kubectl` falls back to a different, stale kubeconfig and fails with misleading x509 "certificate has expired" errors.
- `talosctl` / `topf` — Talos node management
- `sops` / `age` — Secret encryption
- `kubeconform` — YAML schema validation
- `logcli` / `promtool` / `amtool` — Loki, Prometheus/Thanos and Alertmanager CLIs, pinned to the versions running in-cluster. `promtool` also covers Thanos Query (Prometheus HTTP API) and offline rule checks; `amtool` covers Alertmanager config checks
- `gum` — Shell UI used by just recipes for structured logging (`gum log`)
- `gh` — GitHub CLI for issues, PRs, checks, and releases

Run `just` (no args) to list available recipes. Recipes are grouped into modules
invoked as `just <module> <recipe>`. Common commands:

- `just reconcile` — Force Flux to pull latest changes
- `just talos ...` — Talos node operations (apply, diff, upgrade)
- `just volsync ...` — Backup/restore operations
- `just kube ...` — Cluster helpers (sync, debug-node, browse-pvc)

### Git hooks

Pre-commit hooks are managed by lefthook (`.lefthook.toml`), not pre-commit. They:

- Enforce SOPS encryption on `*.sops.yaml` files (`scripts/pre-commit-check-sops.sh`)
- Scan for leaked secrets with TruffleHog
- Format staged `justfile`, mise, JSON, Markdown, and YAML files
- Re-lock `.mise/mise.lock`
- Lint GitHub workflows (zizmor + actionlint) and shell scripts (shellcheck)

### Agent integrations

When automating or investigating from this repo, prefer local CLI and cluster access over MCP servers:

- **GitHub** — Use `gh` for all github.com interactions (issues, PRs, checks, releases, API queries). Do not use the GitHub MCP server.
- **Grafana** — Query and explore via local access (e.g. `kubectl port-forward`, the in-cluster Grafana URL, or direct HTTP to the homelab instance). Do not use the Grafana MCP server.

## Style and Conventions

- All Kubernetes manifests are YAML with `---` document separators.
- Use 2-space indentation for YAML.
- Image tags should include the SHA256 digest (`tag@sha256:...`) for reproducibility.
- Renovate manages dependency updates (`.renovaterc.json5`).
- Keep HelmRelease values minimal — only override what differs from chart defaults.
- Security contexts: prefer `runAsNonRoot`, `readOnlyRootFilesystem`, and drop all capabilities.

## Commit Conventions

- Follow Conventional Commits for commit subjects.
- Prefer the format `<type>(<scope>): <summary>` and use lowercase types such as `fix`, `feat`, and `chore`.
- Write the subject in imperative style and avoid title-case freeform subjects.
- For manual or non-trivial changes, include a commit body that briefly explains the rationale for the change and any important implementation context.
- Keep commit bodies concise; explain why the change was needed before listing mechanical details.
