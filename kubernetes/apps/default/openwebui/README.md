# Open WebUI

Web interface for LLM interaction, pointed at our local Ollama instance.

## Architecture

```
browser → chat.securimancy.com → envoy-internal → openwebui pod (8080)
                                                        ↓
                                          OLLAMA_BASE_URL=https://ollama.securimancy.com
                                                        ↓
                                          envoy-internal HTTPRoute (injects Bearer token)
                                                        ↓
                                          ollama-proxy Service → sardior:11435 (nginx)
                                                        ↓
                                          ollama @ 127.0.0.1:11434
```

## Ollama Authentication

The Envoy Gateway `RequestHeaderModifier` on the `ollama-proxy` HTTPRoute injects the
`Authorization: Bearer` header automatically. Open WebUI doesn't need to know the API key --
it just calls `https://ollama.securimancy.com` and Envoy handles auth.

The API key is stored in `cluster-secrets` (sops-encrypted) as `SECRET_OLLAMA_API_KEY`
and substituted into the HTTPRoute via Flux `postBuild`.

## Storage

- 5Gi iSCSI PVC at `/app/backend/data` for SQLite DB, chat history, and user uploads

## Environment

| Variable | Value | Notes |
|---|---|---|
| `OLLAMA_BASE_URL` | `https://ollama.securimancy.com` | Routed via envoy-internal |
| `ENABLE_OPENAI_API` | `false` | No external LLM providers |
| `ENABLE_PERSISTENT_CONFIG` | `false` | Env vars always take precedence |
| `WEBUI_SECRET_KEY` | (from Secret) | Session signing key |

## Prerequisites

- ollama-proxy deployed (see `kubernetes/apps/default/ollama-proxy/`)
- democratic-csi iSCSI storage provisioner
