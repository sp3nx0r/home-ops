# ZeroClaw — Kubernetes Deployment

Personal AI assistant (Jarvis persona) running on the Securimancy homelab cluster.

## Architecture

```
Pod: zeroclaw
├── init: init-web       — copies web UI assets from image to emptyDir
├── container: app       — zeroclaw v0.7.5-debian (gateway + agent runtime)
└── container: signal-cli — signal-cli-rest-api v0.99 (Signal bridge sidecar)
```

- **Namespace**: `zeroclaw` (isolated from other workloads)
- **Storage**: 5Gi iSCSI PVC with subPath mounts (`zeroclaw-data/`, `signal-data/`)
- **Ingress**: Envoy Gateway HTTPRoute at `zeroclaw.${SECRET_DOMAIN}`
- **Auth**: OIDC SecurityPolicy via PocketID — pairing is disabled
- **Backups**: VolSync + Kopia

## Provider Configuration

ZeroClaw talks to the local Ollama server through `ollama-proxy` (nginx reverse
proxy on sardior at `192.168.5.70:11435`). The proxy requires Bearer token auth.

### Key learnings (v0.7.5)

| What | Detail |
|------|--------|
| `default_provider` | Must be a **built-in kind** or `custom:URL` shorthand — NOT an alias from `[providers.models.*]` |
| Native `ollama` kind | **Ignores `api_key`** entirely — no auth header is sent |
| `custom:` provider | Uses `AuthStyle::Bearer` but resolves credentials from `ZEROCLAW_API_KEY` env var (generic fallback), NOT from the `[providers.models.*]` table or `OLLAMA_API_KEY` |
| `openai-compatible` kind | Works with `[providers.models.*]` table entries, but `default_provider` can't reference table aliases — causes "Unknown provider" |

### Working configuration

**`config.toml`** (lives on the iSCSI PVC at `/zeroclaw-data/config.toml`, **not** a ConfigMap):

```toml
schema_version = 2
default_provider = "custom:http://ollama-proxy.default.svc.cluster.local:11435/v1"
default_model = "qwen3.5:35b"

[autonomy]
level = "supervised"

[gateway]
require_pairing = false

[identity]
format = "markdown"

[web_search]
provider = "searxng"
searxng_instance_url = "http://searxng.default.svc.cluster.local:8080"
```

**Environment variables** (set on the app container):

| Variable | Source | Purpose |
|----------|--------|---------|
| `ZEROCLAW_API_KEY` | `${SECRET_OLLAMA_API_KEY}` from cluster-secrets | Bearer token for ollama-proxy auth |
| `ZEROCLAW_WORKSPACE` | Hardcoded `/zeroclaw-data` | Workspace root on PVC |
| `ZEROCLAW_GATEWAY_PORT` | `42617` | Gateway listen port |
| `ZEROCLAW_GATEWAY_HOST` | `0.0.0.0` | Bind to all interfaces |
| `ZEROCLAW_WEB_DIST_DIR` | `/web-dist` | Web UI assets (emptyDir, copied by init-web) |
| `ZEROCLAW_ALLOW_PUBLIC_BIND` | `true` | Allow non-loopback bind |

## Config Management

The `config.toml` is **not** managed by a ConfigMap. It lives directly on the
iSCSI PVC and is writable by ZeroClaw (required for schema migrations and
`zeroclaw config set`). The initial seed was written manually; subsequent changes
persist across restarts via the PVC.

The `configmap.yaml` in this directory is vestigial and not mounted. It will be
removed once the deployment is stable.

## Network Policy

`CiliumNetworkPolicy` with default-deny and explicit allowlists:

- **Egress**: ollama-proxy (`192.168.5.70:11435` via toCIDR), SearXNG (`8080`),
  DNS (`kube-dns:53`), Discord/Signal external (`world:443`)
- **Ingress**: Envoy Gateway (`42617`), Prometheus metrics scraping (`42617`)

## Channels

| Channel | Status | Notes |
|---------|--------|-------|
| Web Dashboard | Working | OIDC-protected via SecurityPolicy |
| Signal | Pending | signal-cli sidecar running, needs device linking |
| Discord | Pending | Bot token in secret, needs channel config |

## Secrets

All `*.sops.yaml` files must be encrypted before commit:

- `secret.sops.yaml` — Discord bot token, Signal phone, ZeroClaw API key
- `oidc-secret.sops.yaml` — PocketID OIDC client secret
- `volsync-secret.sops.yaml` — Kopia backup credentials
- `persona-secret.sops.yaml` — SOUL.md, IDENTITY.md, USER.md persona files

## Troubleshooting

Currently using the `-debian` image tag for shell access (`bash`, `curl`, etc.).
Switch back to the distroless tag (`v0.7.5`) once stable.

Flux is **suspended** for iterative development:
```bash
# Resume when ready
flux resume kustomization zeroclaw -n zeroclaw
flux resume helmrelease zeroclaw -n zeroclaw
```
