# Speaches STT Deployment on sardior (Dual-Backend)

> Hardware: Miniforum MS-S1 MAX (Ryzen AI MAX+ 395 / Radeon 8060S, 128 GB unified, 2 TB NVMe)
> Hostname: sardior (192.168.5.70)
> Purpose: OpenAI-compatible STT server for Whispering desktop app
> Backend: Speaches (faster-whisper, CPU mode) with whisper.cpp (Vulkan GPU) as alternative

## GPU Acceleration Status

### whisper.cpp — Vulkan (working)

whisper.cpp is built with `GGML_VULKAN=ON` and uses the Mesa RADV driver (v26.0.3) for GPU
acceleration on the integrated Radeon 8060S. This completely bypasses the ROCm/HIP issues.
The build also enables `GGML_NATIVE=ON` (AVX-512 + BF16) and `GGML_LTO=ON`.

### ROCm/HIP (still blocked, informational only)

**Issue:** [ggml-org/whisper.cpp#3553](https://github.com/ggml-org/whisper.cpp/issues/3553) — ROCm 7.1.x breaks HIP backend in ggml.

**PR:** [ggml-org/whisper.cpp#3757](https://github.com/ggml-org/whisper.cpp/pull/3757) — Adds ROCm build with explicit gfx1151 target.

This is no longer a blocker since Vulkan provides GPU acceleration without HIP. Kept as a
reference in case HIP becomes preferable for future workloads.

### Speaches — CPU only

Speaches uses CTranslate2 which has no ROCm or Vulkan backend. It runs in CPU int8 mode.
Still performant on the 16-core Zen 5 but slower than whisper.cpp with Vulkan GPU.

## Architecture

```
Whispering (desktop app)
    │
    │  POST /v1/audio/transcriptions
    │
sardior (MS-S1 MAX) — 192.168.5.70
├── nginx :11436 (API key auth) ──→ active STT backend :8200 (localhost only)
│                                    ├── speaches (faster-whisper, CPU)
│                                    └── whisper-server (whisper.cpp, Vulkan GPU)
├── stt-exporter :8201 (Prometheus metrics)
├── ollama :11434 + nginx :11435 (see ollama-plan.md)
├── node-exporter :9100
├── nginx-exporter :9113
└── nut-client, watchdog, etc.

Talos Cluster (MS-A2 ×3)
├── speaches-proxy Service ──→ 192.168.5.70:11436
│     (EndpointSlice, same pattern as ollama-proxy)
├── HTTPRoute: whisper.${SECRET_DOMAIN}
└── Prometheus scrape: sardior-stt → :8201
```

## Dual-Backend Design

Both backends bind to the same port (8200) — only one is active at a time.
The nginx proxy, exporter, and Kubernetes integration are backend-agnostic.

| Backend | Engine | GPU support | Status |
|---------|--------|-------------|--------|
| **speaches** | faster-whisper (CTranslate2) | CPU only (int8, 16 cores) | Active default |
| **whisper-cpp** | whisper.cpp (GGML) | Vulkan GPU (Mesa RADV) + AVX-512 | Installed, inactive |

### Switching backends

```bash
# Switch to whisper.cpp (GPU-accelerated)
task ansible:ms-s1 -- --tags stt -e stt_backend=whisper-cpp

# Switch back to Speaches (CPU)
task ansible:ms-s1 -- --tags stt -e stt_backend=speaches
```

Or permanently: set `stt_backend: whisper-cpp` in
`ansible/inventory/host_vars/sardior/vars.yml` and run the playbook normally.

## Model Choice

Using `large-v3-turbo` for both backends:
- 809M parameters, ~5GB RAM on CPU with int8
- Near-large-v3 quality (~90%) at ~3x the speed
- Sweet spot for real-time dictation on the Ryzen AI MAX+ 395 (16 cores)

## Whispering Configuration

Settings > Transcription:
- **Service:** OpenAI-compatible / Custom
- **Base URL:** `http://192.168.5.70:11436/v1` (direct LAN) or `https://whisper.securimancy.com/v1` (via gateway)
- **API Key:** value from `vault_speaches_api_key`
- **Model:** `Systran/faster-whisper-large-v3-turbo`

## Monitoring & Alerting

### Metrics collection

| Exporter | Port | Metrics |
|----------|------|---------|
| stt-exporter | 8201 | `stt_up`, `stt_backend_info`, `stt_model_info`, `stt_models_available`, `stt_scrape_duration_seconds` |
| nginx-exporter | 9113 | Request rate, errors, connections (covers both Ollama and STT vhosts) |
| node-exporter | 9100 | CPU usage during transcription |

Prometheus scrape job (`kube-prometheus-stack` additionalScrapeConfigs):

```yaml
- job_name: sardior-stt
  static_configs:
    - targets: ["192.168.5.70:8201"]
      labels:
        instance: sardior
```

### Alert rules

Defined in `kubernetes/apps/o11y/kube-prometheus-stack/app/prometheusrule.yaml`:

| Alert | Condition | For | Severity |
|-------|-----------|-----|----------|
| `STTBackendDown` | `stt_up == 0` | 3m | warning |
| `STTExporterAbsent` | `absent(stt_up{job="sardior-stt"})` | 5m | warning |

Ollama alert rules (`OllamaBackendDown`, `OllamaExporterAbsent`) are documented in
[ollama-plan.md](./ollama-plan.md#alert-rules).

### What each layer tells you

- **`stt_up == 0`** — the backend process (Speaches or whisper.cpp) crashed or is unresponsive
- **`absent(stt_up)`** — the exporter itself is down, or network between cluster and sardior is broken
- **nginx error rates** — clients are hitting the proxy but getting 5xx (backend crashed mid-request)
- **node CPU spike + stt_up == 1** — transcription is running, nothing wrong (normal under load)

## Installation Notes

### Speaches

Not on PyPI — installed from source via `git clone` + `uv sync`.
Key quirks handled by the Ansible playbook:

| Issue | Workaround |
|-------|------------|
| Not on PyPI | Clone from GitHub at tagged release, install with `uv sync` |
| Pins `uv ~=0.8.14` | `lineinfile` removes `required-version` from `pyproject.toml` after clone |
| Requires Python 3.12 exactly | `uv sync` auto-resolves via `UV_PYTHON_INSTALL_DIR=/opt/speaches/python` |
| `ProtectHome=true` blocks `~/.cache` | `HF_HOME=/opt/speaches/hf-cache` env var in systemd unit |
| ctranslate2 ships with `RWE` GNU_STACK | `patchelf --clear-execstack` on kernel 6.x (blocks executable stack) |

### whisper.cpp

No prebuilt Linux binaries in releases — built from source with cmake.

| Issue | Workaround |
|-------|------------|
| No Linux release binaries | `git clone` + `cmake` build on-target |
| Vulkan build needs shader compiler | `glslc` package (not `glslang-tools`) |
| Build idempotency | Triggers on version bump (git changed) OR missing binary |
| GGML models are static (no versioning) | `stat` check skips download; `find`+`exclude` cleans old models on name change |

## Resiliency

| Concern | Solution |
|---------|----------|
| Service crash | `Restart=always` + `RestartSec=10` in systemd |
| Memory pressure | `MemoryMax=16G` (large-v3-turbo needs ~5-6GB on CPU) |
| Model download failure | First startup downloads from HuggingFace; health-check wait loop with 30 retries × 10s |
| Host reboot | Service enabled in multi-user.target |
| Network loss | Whispering falls back to built-in Whisper C++ |
| UPS shutdown | NUT client handles graceful shutdown |
| ctranslate2 kernel compat | `patchelf` clears execstack flag post-install (re-applies on every `uv sync`) |

## Build Optimizations (whisper.cpp)

Built natively on the Ryzen AI MAX+ 395 with:

| Flag | Effect |
|------|--------|
| `GGML_NATIVE=ON` | `-march=native` — AVX-512, BF16, VNNI, FMA |
| `GGML_VULKAN=ON` | GPU offload via Mesa RADV (Radeon 8060S, RDNA 4) |
| `GGML_LTO=ON` | Link-time optimization (~5-10% improvement) |

Build dependencies: `cmake`, `g++`, `make`, `libvulkan-dev`, `glslc`

## Ollama Configuration

See [ollama-plan.md](./ollama-plan.md) for full Ollama documentation (configuration,
GPU tuning, Kubernetes routing, monitoring, and security).

## Usage

```bash
task ansible:ms-s1 -- --tags stt          # deploy/update STT stack
task ansible:ms-s1:dry-run -- --tags stt   # check mode
task ansible:ms-s1 -- --tags stt -e stt_backend=whisper-cpp  # switch backend
```
