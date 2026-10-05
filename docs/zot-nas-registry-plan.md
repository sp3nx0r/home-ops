# Zot Registry on the NAS — Plan

**Status:** proposed (2026-09-30); not started as of 2026-10-01 (no Zot
config in `ansible/`, `talos/` or `kubernetes/`, and Spegel has no
`appendMirrors` yet). Replaces the in-cluster Harbor design
([#553](https://github.com/sp3nx0r/home-ops/pull/553), closed). Research
background lives in that PR's `docs/harbor-registry.md` (branch
`feat/harbor-registry`).

## Goal

A container registry that:

1. is a **pull-through cache** for every upstream the cluster pulls from
   (rate-limit shield, faster pulls, survives upstream outages), and serves
   those images to Talos/containerd as a **registry mirror**;
2. **hosts our own images and Helm OCI charts**;
3. does **not** depend on the cluster being up — no circular dependency where
   the cluster needs the registry, and the registry needs the cluster.

## Why the NAS

The cluster already hard-depends on TrueNAS (`192.168.5.40`): every PVC is
iSCSI/NFS on it. A registry on the NAS adds **no new failure domain**. An
in-cluster registry (Harbor) only serves pulls if Harbor, Postgres, Valkey,
Envoy, Cilium, Garage, and iSCSI are all healthy, which is exactly when you
need it least.

Zot over Harbor/Distribution, for this placement:

- A single static binary with one JSON config file, no database. It's OCI-native (images, Helm charts,
  cosign/notation signatures, referrers).
- Filesystem storage on ZFS is Zot's best-tested path, and it sidesteps the Zot S3
  metadata-loss bug (zot#4336) that ruled it out on Garage.
- Built-in on-demand `sync` (pull-through), retention, a UI, a Prometheus
  `/metrics` endpoint, and optional CVE scanning (Kubescape already covers
  cluster images, so we leave Zot's CVE scanning off).
- It's what bjw-s runs (Zot on the NAS + Talos mirrors) — a proven layout.

## Pull path after the change

containerd resolves mirrors in order, and **falls back to upstream** unless
`skipFallback` is set (we never set it):

```
Spegel (peer node, :29999)  →  Zot on NAS  →  upstream registry
```

If Zot is down, pulls degrade to today's behaviour. If the cluster is down,
Zot is unaffected.

## Design

### Runtime on TrueNAS

- **TrueNAS SCALE 25.10 custom app** (Docker Compose), created/updated
  through `midclt call app.create/app.update` with `custom_app: true` and a
  templated `custom_compose_config`. It's driven from Ansible
  (`ansible/playbooks/truenas-configure.yml`, new `zot` tasks + a Jinja
  compose/config template under `ansible/playbooks/templates/`), matching the
  existing `midclt` pattern. **Verify** that the 25.10 `app.create` schema
  supports this before implementing; fallback: a TrueNAS "Install via YAML"
  app with the same compose, config still templated by Ansible.
- Image: `ghcr.io/project-zot/zot-linux-amd64` (full build: sync, ui, search,
  metrics, scrub), digest-pinned. Renovate can't see the NAS compose, so add a
  Renovate `customManagers` regex for the Ansible var holding the tag@digest.
- Hardening: run as a dedicated unprivileged UID/GID that owns only the Zot
  datasets; `read_only: true`; `cap_drop: [ALL]`;
  `security_opt: [no-new-privileges:true]`; no host network; publish only
  the registry port; memory limit (~1 GiB).

### Storage (ZFS)

| Dataset                  | Contents                              | Snapshots  | B2                                               |
| ------------------------ | ------------------------------------- | ---------- | ------------------------------------------------ |
| `tank/homelab/zot/cache` | Synced upstream content (regenerable) | none       | **excluded**                                     |
| `tank/homelab/zot/local` | Our pushed images/charts              | daily, 14d | included (existing `sp3nx0r-homelab` Cloud Sync) |

Zot `storage.subPaths` maps the cache namespaces (`docker.io/**`, `ghcr.io/**`, …)
to the cache dataset, and everything else to `local`. Set a ZFS `quota` on
each (start with cache 100G, local 50G). Retention (`storage.retention`) drops
cached tags not pulled within 90 days; GC and dedupe stay on.

### Upstreams (`extensions.sync`, `onDemand: true`)

`docker.io` (`registry-1.docker.io`, authenticated with the Docker Hub PAT via
`credentialsFile`), `ghcr.io`, `quay.io`, `registry.k8s.io`, `gcr.io`,
`public.ecr.aws`, `factory.talos.dev` (Talos installer/extension images, so
upgrades benefit too), `mirror.gcr.io` optional. Each is synced into a
`/<upstream-host>` destination prefix so Talos can use `overridePath`.

### Endpoint, TLS, DNS

- Hostname `zot.${SECRET_DOMAIN}` → `192.168.5.40`, published to UniFi DNS by
  a `DNSEndpoint` in `kubernetes/apps/network/unifi-dns/app/dnsendpoint.yaml`.
- TLS: add `zot.securimancy.com` as a SAN on the existing TrueNAS ACME
  certificate (`truenas_cert_*` vars in `hl8/vars.yml`). Mount the renewed
  cert/key read-only into the container and have Zot reload on change (or restart it
  from the renewal hook). Port `5000` (TrueNAS UI keeps 443).
- LAN only: no Cloudflare/tunnel exposure. UniFi firewall should allow
  `:5000` only from the node subnet + workstation.

### Auth

- **Anonymous read** (`accessControl` `anonymousPolicy: ["read"]`) so
  containerd needs no credentials. Everything cached is public anyway.
- **Push/admin**: htpasswd users (bcrypt; hash in Ansible vault/SOPS) plus
  Zot API keys for CI. No Pocket ID OIDC for anything on the pull path, since that
  would reintroduce the cluster dependency. OIDC for the UI is optional later.
- Cached namespaces (`docker.io/**`, …) are read-only for everyone, so nobody can push
  over a cached upstream image.

### Talos

- One `RegistryMirrorConfig` document per upstream in a new
  `talos/all/52-registry-mirrors.yaml`, e.g. `name: docker.io` →
  `endpoints: [{url: https://zot.securimancy.com:5000/v2/docker.io,
overridePath: true}]`. No `skipFallback`. **Verify** the exact Talos 1.14
  document schema with `talosctl validate` before rollout.
- **Spegel:** it writes `/etc/cri/conf.d/hosts` too, and by default
  **replaces** existing mirror config. Set `spegel.appendMirrors: true` in
  `kubernetes/apps/kube-system/spegel/app/helmrelease.yaml` so the resulting
  order is Spegel → Zot → upstream. Ship the Spegel change **before** the Talos
  patch.
- Rollout: `talosctl apply --mode=try` on one node → confirm
  `/etc/cri/conf.d/hosts/docker.io/hosts.toml` contains both endpoints
  (`talosctl read`) → pull a never-cached image and watch Zot's logs → commit →
  remaining nodes. No reboot needed for registry config.

### Observability

- Prometheus static scrape job `nas-zot` → `192.168.5.40:5000/metrics` (same
  pattern as the `sardior-*` jobs); allow Prometheus egress to it in the o11y
  CNP.
- Alerts: `ZotDown` (warning — fallback keeps pulls working), sync error
  rate, dataset > 85% (via truenas-exporter).
- Gatus endpoint `https://zot.${SECRET_DOMAIN}:5000/v2/` (expects 200/401).
- Zot logs → Vector syslog (`192.168.5.24`) if the compose logging driver
  allows it; otherwise rely on metrics.

### Security considerations

- The NAS is the crown-jewel host. This adds an internet-fetching service to
  it. Mitigations: an unprivileged container with its own datasets only, no
  host mounts beyond those + the cert, a read-only rootfs, LAN-only exposure, and an
  anonymous **read-only** API.
- Cache poisoning: mirrors are only used for digest-pinned pulls in practice
  (Renovate pins digests), and containerd verifies content digests, so a
  tampered blob fails to pull. Tag-only pulls are the residual risk.
- Future: Kyverno `verifyImages` / cosign verification works unchanged through
  a mirror.

## Implementation phases

1. **Ansible/TrueNAS**: datasets + quotas, Zot user, cert SAN, compose + Zot
   config templates, `midclt app.create/update` tasks, Docker Hub PAT
   credentials file. Verify with `curl https://zot…:5000/v2/_catalog` and a
   manual `crane pull` through `docker.io` sync.
2. **Cluster side**: UniFi `DNSEndpoint`, Prometheus scrape + CNP egress,
   PrometheusRule, Gatus endpoint.
3. **Spegel** `appendMirrors: true` (merge, confirm Spegel healthy).
4. **Talos mirrors**, rolling one node at a time as above.
5. **Own images**: push path docs (`just` recipe for `oras`/`crane` login +
   push), and optionally move any Helm OCI charts we publish.
6. **Cleanup**: close out the Harbor branch, and drop the Garage `harbor`
   bucket/key and `HARBOR_S3_*` cluster-secrets if they were ever merged
   (they were not).

## Independent follow-up (not Zot-related) — ✅ done

Garage's `data-garage-0` was at 51% of 50Gi, growing ~0.5 GiB/day (Thanos).
It was expanded to **1Ti** in #557 (2026-09-30).

## Interaction with open PRs

- [#562](https://github.com/sp3nx0r/home-ops/pull/562) adds a Spegel CNP and
  keeps Spegel's `nodeIP:29999` / `nodeIP:30021` mirror endpoints, so the
  Spegel → Zot → upstream order above still holds.
- [#558](https://github.com/sp3nx0r/home-ops/pull/558) (Talos host firewall)
  only filters ingress, so node → NAS `:5000` egress is unaffected.

## Open questions

- Is `app.create` with custom compose fully scriptable on 25.10, or do we
  need the YAML-app fallback?
- Are the cache/local quotas (100G/50G) right for the pool's free space?
- Is HTTP on the LAN acceptable instead of TLS (simpler, since Talos accepts HTTP
  endpoints), or do we require TLS as designed?
- Should the UI be OIDC-gated via Pocket ID (UI only, never the pull path)?
