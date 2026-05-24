# Ollama LLM Inference on sardior

> Hardware: Miniforum MS-S1 MAX (Ryzen AI MAX+ 395 / Radeon 8060S, 128 GB unified, 2 TB NVMe)
> Hostname: sardior (192.168.5.70)
> Purpose: Self-hosted LLM inference server for coding, chat, and agentic workloads
> GPU: AMD Radeon 8060S (RDNA 4) via ROCm + Vulkan, unified memory with CPU

## Architecture

```
Clients (Cursor, Open WebUI, CLI tools)
    │
    │  POST /api/chat, /api/generate, etc.
    │
sardior (MS-S1 MAX) — 192.168.5.70
├── ollama :11434 (localhost only, keep_alive=-1)
│   └── nginx :11435 (API key auth, Bearer token)
├── ollama-exporter :8000 (Prometheus metrics)
├── nginx-exporter :9113 (request/connection metrics)
├── node-exporter :9100 (host CPU/memory/disk)
└── nut-client (graceful UPS shutdown)

Talos Cluster (MS-A2 ×3)
├── ollama-proxy Service ──→ 192.168.5.70:11435
│     (EndpointSlice, same pattern as speaches-proxy)
├── HTTPRoute: ollama.${SECRET_DOMAIN}
│     (envoy-internal gateway, injects Bearer token)
└── Prometheus scrape: sardior-ollama → :8000
```

## Configuration

All variables live in `ansible/inventory/host_vars/sardior/vars.yml`.

| Setting | Value | Reason |
|---------|-------|--------|
| `ollama_version` | (Renovate-managed) | Pinned via `github-releases` datasource |
| `ollama_host` | `127.0.0.1` | Localhost-only; nginx handles external access |
| `ollama_port` | `11434` | Default Ollama port |
| `ollama_keep_alive` | `-1` (never unload) | 128 GB unified memory; model stays GPU-resident permanently |
| `ollama_num_parallel` | `2` | Concurrent request slots per model |
| `ollama_context_length` | `65536` | Full 64K context window for Qwen 3.5 |
| `ollama_load_timeout` | `30m` | Large models can take time to load on first pull |
| `ollama_flash_attention` | `true` | Faster attention computation on supported models |

### Environment Variables (systemd override)

The Ansible playbook deploys `/etc/systemd/system/ollama.service.d/override.conf`:

```ini
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
Environment="OLLAMA_KEEP_ALIVE=-1"
Environment="OLLAMA_NUM_PARALLEL=2"
Environment="OLLAMA_CONTEXT_LENGTH=65536"
Environment="OLLAMA_LOAD_TIMEOUT=30m"
Environment="OLLAMA_FLASH_ATTENTION=true"
Environment="HSA_ENABLE_SDMA=0"
Environment="GPU_MAX_HW_QUEUES=1"
```

`HSA_ENABLE_SDMA=0` and `GPU_MAX_HW_QUEUES=1` are ROCm tuning flags to prevent GPU hangs
on RDNA 4 with large batch sizes.

### Models

Managed via the `ollama_models` list in vars. Pulled on every playbook run via `/api/pull`:

| Model | Use Case |
|-------|----------|
| `qwen3-coder:30b` | Code generation and review |
| `qwen3.5:35b` | General chat and reasoning |
| `frob/qwen3.5-instruct:35b` | Instruction-following (custom quant) |
| `gemma4:e4b` | Lightweight/fast tasks |
| `gemma3:27b` | Alternative reasoning model |

With `keep_alive=-1`, the last-used model remains in GPU memory indefinitely. The 128 GB
unified memory can hold the 35B Q4 models (~20 GB) with ample room for KV cache and
concurrent requests.

## GPU & Memory Tuning

### Kernel Parameters

Deployed to `/etc/sysctl.d/99-ollama-tuning.conf`:

| Sysctl | Value | Purpose |
|--------|-------|---------|
| `vm.vfs_cache_pressure` | `200` | Aggressively reclaim dentries/inodes for GPU DMA buffers |
| `vm.min_free_kbytes` | `1048576` (1 GB) | Reserve free memory for DMA allocations |
| `vm.watermark_boost_factor` | `15000` | Boost memory reclaim when approaching low watermark |
| `vm.watermark_scale_factor` | `50` | Wider gap between low/high watermarks |

### GRUB Parameters

```
quiet pcie_aspm=off amdgpu.gttsize=98304 ttm.pages_limit=25165824
```

- `pcie_aspm=off` — Disable PCIe power saving (latency sensitive)
- `amdgpu.gttsize=98304` — 96 GB GTT (system memory visible to GPU)
- `ttm.pages_limit=25165824` — Allow ~96 GB in Translation Table Maps

## Nginx Reverse Proxy

Ollama binds to localhost only. Nginx provides:
- Bearer token authentication (API key from `vault_ollama_api_key`)
- Streaming/chunked response support
- 600s read/send timeouts (long inference for large contexts)
- HTTP/1.1 keepalive to Ollama backend

Nginx listens on `192.168.5.70:11435` (the `ollama_proxy_listen` address).

```nginx
server {
    listen 192.168.5.70:11435;

    location / {
        if ($http_authorization != "Bearer <API_KEY>") {
            return 401 '{"error": "unauthorized"}';
        }

        proxy_pass http://127.0.0.1:11434;
        proxy_set_header Host 127.0.0.1;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_buffering off;
        proxy_read_timeout 600s;
        proxy_send_timeout 600s;

        proxy_set_header Connection "";
        proxy_http_version 1.1;
        chunked_transfer_encoding on;
    }
}
```

The same nginx instance also hosts:
- STT proxy on `:11436` (see [speaches-stt-plan.md](./speaches-stt-plan.md))
- `stub_status` on `127.0.0.1:8080` for the nginx-prometheus-exporter

## Kubernetes Integration

Ollama is exposed to the Talos cluster via a headless `Service` + `EndpointSlice` pattern
(no in-cluster pods needed):

### Service + EndpointSlice

`kubernetes/apps/default/ollama-proxy/app/ollama-proxy.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: ollama-proxy
spec:
  ports:
    - name: http
      port: 11435
      targetPort: 11435
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: ollama-proxy
  labels:
    kubernetes.io/service-name: ollama-proxy
addressType: IPv4
ports:
  - name: http
    port: 11435
    protocol: TCP
endpoints:
  - addresses:
      - 192.168.5.70
    conditions:
      ready: true
```

### HTTPRoute (Gateway API)

An internal-only HTTPRoute injects the Bearer token automatically, so in-cluster consumers
(Open WebUI, etc.) don't need to know the API key:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: ollama-proxy
spec:
  hostnames:
    - ollama.${SECRET_DOMAIN}
  parentRefs:
    - name: envoy-internal
      namespace: network
      sectionName: https
  rules:
    - filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: Authorization
                value: "Bearer ${SECRET_OLLAMA_API_KEY}"
      backendRefs:
        - name: ollama-proxy
          port: 11435
```

This means any in-cluster service can reach Ollama at `http://ollama-proxy.default.svc:11435`
(direct) or `https://ollama.<domain>` (via gateway with auto-injected auth).

### Flux Kustomization

`kubernetes/apps/default/ollama-proxy/ks.yaml` uses `postBuild.substituteFrom` to inject
`SECRET_DOMAIN` and `SECRET_OLLAMA_API_KEY` from `cluster-secrets`.

## Monitoring & Alerting

### Prometheus Exporter

A custom Python exporter (`ollama_exporter.py`) runs as a systemd service on sardior,
querying Ollama's REST API (`/api/ps` and `/api/tags`) every scrape.

| Metric | Type | Description |
|--------|------|-------------|
| `ollama_up` | gauge | 1 if Ollama API responds, 0 otherwise |
| `ollama_models_loaded` | gauge | Number of models currently in memory |
| `ollama_models_available` | gauge | Number of models on disk |
| `ollama_model_size_bytes` | gauge | Total size per loaded model |
| `ollama_model_vram_bytes` | gauge | VRAM consumed per loaded model |
| `ollama_model_gpu_percent` | gauge | Percent of model offloaded to GPU |
| `ollama_model_context_length` | gauge | Context window of loaded model |
| `ollama_model_disk_bytes` | gauge | Disk size per available model |
| `ollama_total_disk_bytes` | gauge | Total disk for all models |
| `ollama_scrape_duration_seconds` | gauge | Time to collect metrics |
| `ollama_exporter_info` | gauge | Exporter version metadata |

All model metrics include labels: `model`, `family`, `parameter_size`, `quantization`.

### Prometheus Scrape Job

In `kube-prometheus-stack` additionalScrapeConfigs:

```yaml
- job_name: sardior-ollama
  static_configs:
    - targets: ["192.168.5.70:8000"]
      labels:
        instance: sardior
```

### Alert Rules

Defined in `kubernetes/apps/o11y/kube-prometheus-stack/app/prometheusrule.yaml`:

| Alert | Expression | For | Severity | Description |
|-------|-----------|-----|----------|-------------|
| `OllamaBackendDown` | `ollama_up == 0` | 3m | warning | Ollama API unreachable — LLM inference unavailable |
| `OllamaExporterAbsent` | `absent(ollama_up{job="sardior-ollama"})` | 5m | warning | Exporter not being scraped — service or network down |

### What each layer tells you

- **`ollama_up == 0`** — Ollama process crashed or is unresponsive
- **`absent(ollama_up)`** — The exporter itself is down, or network between cluster and sardior is broken
- **`ollama_models_loaded == 0` with `keep_alive=-1`** — Model was evicted (shouldn't happen) or Ollama restarted without a request to reload
- **`ollama_model_gpu_percent < 100`** — Model is partially CPU-offloaded (memory pressure or model too large)
- **nginx error rates via sardior-nginx job** — Clients hitting proxy but getting 5xx (Ollama crashed mid-inference)

## Installation & Updates

### Ansible Deployment

```bash
task ansible:ms-s1 -- --tags ollama   # deploy/update Ollama + exporter
task ansible:ms-s1 -- --tags models   # pull models only
task ansible:ms-s1:dry-run -- --tags ollama  # check mode
```

### Installation Method

Ollama is installed via the official install script (`ollama.com/install.sh`) with version
pinning via the `OLLAMA_VERSION` environment variable. The Ansible task is idempotent:
it checks the currently installed version and only re-runs the script when the configured
version differs.

Renovate manages version bumps via the `github-releases` datasource comment in vars.

### Update Flow

1. Renovate opens a PR bumping `ollama_version` in `vars.yml`
2. Merge the PR
3. Run `task ansible:ms-s1 -- --tags ollama`
4. Ollama restarts with the new binary; models remain cached

## Resiliency

| Concern | Solution |
|---------|----------|
| Process crash | `Restart=always` in Ollama's built-in systemd unit |
| Model eviction | `keep_alive=-1` keeps model GPU-resident permanently |
| Host reboot | Ollama enabled in `multi-user.target`; first request post-boot loads model |
| Long inference timeout | Nginx `proxy_read_timeout 600s` (10 min) |
| UPS power loss | NUT client triggers graceful shutdown |
| GPU hang | `HSA_ENABLE_SDMA=0` + `GPU_MAX_HW_QUEUES=1` mitigates RDNA 4 instability |
| Memory pressure | Kernel tuning (min_free_kbytes, watermarks) reserves DMA headroom |

## Security

- Ollama binds to `127.0.0.1` only — never exposed directly to the network
- Nginx enforces Bearer token auth on all external requests
- Kubernetes HTTPRoute injects the token via `RequestHeaderModifier` — in-cluster consumers
  authenticate transparently
- API key stored in SOPS-encrypted secrets (`vault_ollama_api_key` in Ansible,
  `SECRET_OLLAMA_API_KEY` in cluster-secrets)
- Network hardening sysctls applied (rp_filter, no redirects, no forwarding, etc.)

## Related Documentation

- [STT (Speaches / whisper.cpp)](./speaches-stt-plan.md) — Transcription services on the same host
- `ansible/inventory/host_vars/sardior/vars.yml` — All configurable variables
- `ansible/playbooks/ms-s1-configure.yml` — Full Ansible playbook
- `kubernetes/apps/default/ollama-proxy/` — Kubernetes manifests
