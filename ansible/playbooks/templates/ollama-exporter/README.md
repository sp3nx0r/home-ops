# Ollama Prometheus Exporter

Custom Prometheus exporter for Ollama, deployed to `sardior` (MS-S1 MAX) as a
native systemd service. Pure Python — zero external dependencies.

## Background

**Comparison date**: 2026-05-02

Evaluated three approaches for monitoring Ollama from our Prometheus stack:

| Option | Verdict |
|--------|---------|
| [lucavb/ollama-exporter](https://github.com/lucavb/ollama-exporter) (TypeScript/Docker) | Required Docker CE on a bare-metal box just for one container. Metrics were less granular — no VRAM breakdown. |
| [akshaypgore/llm-ansible](https://github.com/akshaypgore/llm-ansible) custom Python exporter | Excellent baseline — stdlib-only, systemd-native. Missing GPU metrics (`size_vram`) because it targeted CPU-only setups. |
| Native Ollama `/metrics` endpoint ([PR #11159](https://github.com/ollama/ollama/pull/11159)) | Still an open PR as of 2026-05-02. Not yet merged. |

We adopted the akshaypgore pattern and extended it for GPU monitoring on our
Radeon 8060S (ROCm) setup.

## Ollama API Endpoints Used

| Endpoint | Docs | What we extract |
|----------|------|-----------------|
| `GET /api/ps` | [docs.ollama.com/api/ps](https://docs.ollama.com/api/ps) | Running models, size, VRAM, context length, model details |
| `GET /api/tags` | [docs.ollama.com/api/tags](https://docs.ollama.com/api/tags) | Downloaded models, disk size, model details |
| `GET /` | — | Health check (200 = up) |

### `/api/ps` response schema (evaluated 2026-05-02)

```
models[].name              string   Model name
models[].size              int      Total model size in bytes
models[].size_vram         int      VRAM usage in bytes (omitted when 0)
models[].context_length    int      Context window size
models[].expires_at        string   ISO 8601 unload time
models[].details.family    string   e.g. "qwen3", "gemma3"
models[].details.parameter_size    string   e.g. "32B", "4.3B"
models[].details.quantization_level string  e.g. "Q4_K_M"
```

### `/api/tags` response schema (evaluated 2026-05-02)

```
models[].name              string   Model name
models[].size              int      Disk size in bytes
models[].modified_at       string   ISO 8601 last modified
models[].details.family    string   e.g. "qwen3"
models[].details.parameter_size    string   e.g. "32B"
models[].details.quantization_level string  e.g. "Q4_K_M"
```

## Metrics Reference

### Exporter metadata

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `ollama_exporter_info` | gauge | `version` | Exporter version identifier |
| `ollama_scrape_duration_seconds` | gauge | — | Time taken to collect all metrics |

### Health

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `ollama_up` | gauge | — | 1 if Ollama API responds 200, 0 otherwise |

### Running models (from `/api/ps`)

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `ollama_models_loaded` | gauge | — | Count of models currently in memory |
| `ollama_model_size_bytes` | gauge | `model`, `family`, `parameter_size`, `quantization` | Total model footprint (RAM + VRAM) |
| `ollama_model_vram_bytes` | gauge | `model`, `family`, `parameter_size`, `quantization` | Bytes loaded into GPU VRAM |
| `ollama_model_gpu_percent` | gauge | `model`, `family`, `parameter_size`, `quantization` | Percent of model in VRAM (`size_vram / size * 100`) |
| `ollama_model_context_length` | gauge | `model`, `family`, `parameter_size`, `quantization` | Active context window size |

### Available models (from `/api/tags`)

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `ollama_models_available` | gauge | — | Count of models downloaded on disk |
| `ollama_model_disk_bytes` | gauge | `model`, `family`, `parameter_size`, `quantization` | Disk space per model |
| `ollama_total_disk_bytes` | gauge | — | Sum of all model disk usage |

## Files

```
ansible/playbooks/templates/ollama-exporter/
├── ollama_exporter.py.j2   # Jinja2 template → deployed as .py
└── README.md               # this file
```

## Deployment

Managed by Ansible — see `ansible/playbooks/ms-s1-configure.yml` (tag: `monitoring`).

The `.j2` template is rendered by Ansible's `template` module, which substitutes
`{{ ollama_port }}` and `{{ ollama_exporter_port }}` from host vars. The rest of
the script is wrapped in `{% raw %}` to protect Python f-string braces from Jinja.

- **Source**: `ansible/playbooks/templates/ollama-exporter/ollama_exporter.py.j2`
- **Deployed to**: `/opt/ollama_exporter/ollama_exporter.py`
- **Service**: `ollama-exporter.service` (systemd, runs as `ollama` user)
- **Port**: 8000
- **Endpoints**: `/metrics`, `/health`
- **Dependencies**: Python 3 stdlib only (`http.server`, `urllib.request`, `json`, `time`)

## Prometheus Scrape Config

```yaml
- job_name: sardior-ollama
  static_configs:
    - targets: ["192.168.5.70:8000"]
      labels:
        instance: sardior
```

## Example Output

```
ollama_exporter_info{version="1.0.0"} 1
ollama_up 1
ollama_models_loaded 1
ollama_model_size_bytes{model="qwen3:32b",family="qwen3",parameter_size="32B",quantization="Q4_K_M"} 19853928448
ollama_model_vram_bytes{model="qwen3:32b",family="qwen3",parameter_size="32B",quantization="Q4_K_M"} 19853928448
ollama_model_gpu_percent{model="qwen3:32b",family="qwen3",parameter_size="32B",quantization="Q4_K_M"} 100.0
ollama_model_context_length{model="qwen3:32b",family="qwen3",parameter_size="32B",quantization="Q4_K_M"} 65536
ollama_models_available 5
ollama_model_disk_bytes{model="qwen3:32b",family="qwen3",parameter_size="32B",quantization="Q4_K_M"} 19853928448
ollama_total_disk_bytes 72431960064
ollama_scrape_duration_seconds 0.0123
```

## Future Considerations

- **Native Ollama `/metrics`**: [PR #11159](https://github.com/ollama/ollama/pull/11159) would
  add native Prometheus metrics. If merged, this exporter becomes redundant. Check periodically.
- **Lemonade**: Evaluated AMD Lemonade as an alternative to Ollama on 2026-05-02.
  Performance gains (~2x throughput on AMD silicon) are real but ecosystem maturity,
  monitoring tooling, and API compatibility gaps made it premature. Revisit in 6-12 months.
  See `docs/ms-s1-provisioning-plan.md` for the full comparison.
