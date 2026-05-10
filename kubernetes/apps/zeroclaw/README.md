# ZeroClaw — Kubernetes Deployment

Personal AI assistant ("Wintermute" persona) running on the Securimancy homelab cluster.

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
- **Auth**: OIDC SecurityPolicy via PocketID — gateway pairing is disabled
- **Backups**: VolSync + Kopia
- **Persona files**: SOUL.md, IDENTITY.md, USER.md mounted read-only from `zeroclaw-persona` Secret

## Provider Configuration

ZeroClaw talks to the local Ollama server through `ollama-proxy` (nginx reverse
proxy on ms-s1 at `192.168.5.70:11435`). The proxy requires Bearer token auth.

### Model: `frob/qwen3.5-instruct:35b`

Qwen3.5-35B-A3B — 35B total parameters, 3B active per token (MoE, 256 experts).
The `frob/qwen3.5-instruct` variant uses a modified chat template that **removes
the `<think>` tag**, disabling the model's hidden thinking chain. This is critical
because:

- With thinking: ~1,200 tokens per simple question (~1,000 hidden), 29+ seconds
- Without thinking: ~60-270 tokens, 1-7 seconds, same quality

The native Ollama `think=false` parameter only works via `/api/chat`, not the
OpenAI-compatible `/v1/chat/completions` endpoint that ZeroClaw v0.7.5 uses with
the `custom:` provider. The template-level fix bypasses this limitation.

### Key learnings (v0.7.5)

| What | Detail |
|------|--------|
| `default_provider` | Must be a **built-in kind** or `custom:URL` shorthand — NOT an alias from `[providers.models.*]` |
| Native `ollama` kind | Not supported in v0.7.5 — causes "Unknown provider" |
| `custom:` provider | Uses `AuthStyle::Bearer`, resolves credentials from `ZEROCLAW_API_KEY` env var (generic fallback) |
| Thinking control | v0.7.5 `custom:` provider can't pass `think=false`; use a no-think model variant instead |

### Working configuration

**`config.toml`** (lives on the iSCSI PVC at `/zeroclaw-data/config.toml`, **not** a ConfigMap):

```toml
schema_version = 2

[providers]
default_provider = "custom:http://ollama-proxy.default.svc.cluster.local:11435/v1"
fallback = "custom:http://ollama-proxy.default.svc.cluster.local:11435/v1"

[providers.models."custom:http://ollama-proxy.default.svc.cluster.local:11435/v1"]
model = "frob/qwen3.5-instruct:35b"

[autonomy]
level = "supervised"

[runtime]
kind = "native"
reasoning_enabled = false

[gateway]
require_pairing = false

[channels.signal]
account = "+14795518443"
allowed_from = ["+18323709367"]
enabled = true
http_url = "http://localhost:6002"

[web_search]
provider = "searxng"
searxng_instance_url = "http://searxng.default.svc.cluster.local:8080"
```

> **Note**: ZeroClaw auto-expands `config.toml` with many default sections on first
> run. The snippet above shows only the sections we explicitly configured. The full
> file on the PVC is much larger.

### Ollama server tuning (ms-s1)

| Setting | Value | Rationale |
|---------|-------|-----------|
| `OLLAMA_CONTEXT_LENGTH` | `65536` | Full 64K context window |
| `OLLAMA_NUM_PARALLEL` | `2` | Prevent request queuing with MoE's low active param count |
| `OLLAMA_FLASH_ATTENTION` | `True` | Memory-efficient attention for large contexts |
| `OLLAMA_KEEP_ALIVE` | `24h` | Keep model loaded (avoid 3-4s cold load) |

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

## Signal Channel

### Architecture

The signal-cli sidecar runs in `json-rpc` mode by default, which starts signal-cli
with `--tcp` on port 6001 (used by the REST API wrapper on port 8080). ZeroClaw
requires the native signal-cli HTTP interface for SSE message streaming, which is
only available via the `--http` flag.

A **lifecycle postStart hook** on the signal-cli container patches the supervisord
config after startup to add `--http 127.0.0.1:6002` alongside the existing
`--tcp 127.0.0.1:6001`. This gives us both:

- **Port 8080** — signal-cli-rest-api wrapper (admin tasks: profiles, registration)
- **Port 6001** — signal-cli TCP JSON-RPC (internal, used by the REST API wrapper)
- **Port 6002** — signal-cli native HTTP (SSE events + JSON-RPC over HTTP, used by ZeroClaw)

### Registration

The Signal account was registered via **SMS verification** (not QR code linking)
because the number (+14795518443) is a Google Voice number. The registration flow:

1. Generate a captcha token at `https://signalcaptchas.org/registration/generate.html`
2. POST to `/v1/register/+14795518443` with the captcha token via the REST API wrapper
3. Enter the SMS verification code via `/v1/register/+14795518443/verify/<code>`

The Signal profile name is set to **Wintermute**.

### Troubleshooting signal-cli

```bash
# Check registration status
kubectl -n zeroclaw exec deploy/zeroclaw -c signal-cli -- \
  curl -s http://localhost:8080/v1/accounts

# Verify HTTP endpoint health (ZeroClaw's SSE source)
kubectl -n zeroclaw exec deploy/zeroclaw -c signal-cli -- \
  curl -s http://127.0.0.1:6002/api/v1/check

# Send a test message via REST API wrapper
kubectl -n zeroclaw exec deploy/zeroclaw -c signal-cli -- \
  curl -s -X POST http://localhost:8080/v2/send \
  -H 'Content-Type: application/json' \
  -d '{"message": "test", "number": "+14795518443", "recipients": ["+18323709367"]}'

# If HTTP endpoint is down, manually patch supervisord
kubectl -n zeroclaw exec deploy/zeroclaw -c signal-cli -- bash -c '
  supervisorctl stop signal-cli-json-rpc-1
  sed -i "s|daemon  --tcp \(.*\)|daemon --tcp \1 --http 127.0.0.1:6002|" \
    /etc/supervisor/conf.d/signal-cli-json-rpc-1.conf
  supervisorctl reread
  supervisorctl update'
```

## Network Policy

`CiliumNetworkPolicy` with default-deny and explicit allowlists:

- **Egress**: ollama-proxy (`192.168.5.70:11435` via toCIDR), SearXNG (`8080`),
  DNS (`kube-dns:53`), Discord/Signal external (`world:443`)
- **Ingress**: Envoy Gateway (`42617`), Prometheus metrics scraping (`42617`)

## Channels

| Channel | Status | Notes |
|---------|--------|-------|
| Web Dashboard | Working | OIDC-protected via SecurityPolicy, pairing disabled |
| Signal | Working | SMS-registered as Wintermute, SSE via native HTTP on port 6002 |
| Discord | Pending | Bot token in secret, needs channel config in `config.toml` |

## Secrets

All `*.sops.yaml` files must be encrypted before commit:

- `secret.sops.yaml` — Discord bot token, Signal phone, ZeroClaw API key
- `oidc-secret.sops.yaml` — PocketID OIDC client secret
- `volsync-secret.sops.yaml` — Kopia backup credentials
- `persona-secret.sops.yaml` — SOUL.md, IDENTITY.md, USER.md persona files

## Troubleshooting

Currently using the `-debian` image tag for shell access (`bash`, `curl`, etc.).
Switch back to the distroless tag (`v0.7.5`) once stable.

```bash
# Check ZeroClaw status
kubectl -n zeroclaw exec deploy/zeroclaw -c app -- zeroclaw status

# View recent logs
kubectl -n zeroclaw logs deploy/zeroclaw -c app --tail=50

# Suspend Flux for iterative development
flux suspend kustomization zeroclaw -n zeroclaw
flux suspend helmrelease zeroclaw -n zeroclaw

# Resume Flux
flux resume kustomization zeroclaw -n zeroclaw
flux resume helmrelease zeroclaw -n zeroclaw
```
