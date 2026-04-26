# Open WebUI

Web interface for LLM interaction, pointed at our local Ollama instance.

## Backend

- **Ollama endpoint:** ms-s1 (get IP/hostname and port before deploying)
- Set `OLLAMA_BASE_URL` env var to point at the ms-s1 Ollama instance

## Prerequisites

- [ ] csi-driver-nfs — Needs a PVC for chat history / user data
- [ ] Confirm ms-s1 Ollama is accessible from the k8s network
- [ ] Determine ms-s1 IP/hostname and Ollama port (default 11434)

## Notes

- Route on `envoy-internal` at `chat.securimancy.com` or `ai.securimancy.com`
- Deploy via app-template HelmRelease
- Image: `ghcr.io/open-webui/open-webui`
