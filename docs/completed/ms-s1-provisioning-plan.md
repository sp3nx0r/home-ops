# MS-S1 Provisioning Plan

> Hardware: Miniforum MS-S1 MAX (Ryzen AI MAX+ 395 / Radeon 8060S, 128 GB unified, 2 TB NVMe)
> Hostname: sardior (D&D Ruby Dragon — psionic god of gem dragons)
> OS: Ubuntu 26.04 LTS (Resolute Raccoon)
> Purpose: Single-purpose GPU inference server (Ollama)
> Network: 192.168.5.70 (RJ45 to UniFi LAN)

## Decision Record

### Previous Setup: Proxmox VE + LXC

The MS-S1 originally ran Proxmox VE with two unprivileged LXC containers:

| CT | Name | Purpose | Resources |
|----|------|---------|-----------|
| 100 | ollama | LLM inference, GPU passthrough, nginx API proxy | 16 cores, 96 GB, 492 GB disk |
| 101 | openclaw | AI agent (chatbot via Signal), firewalled | 4 cores, 4 GB, 16 GB disk |

### Why We Moved Away from Proxmox

**Proxmox was a hypervisor for a job that didn't need one:**
- No VMs — just two LXC containers
- No HA, no clustering, no storage backends
- ~1-2 GB RAM overhead for pveproxy, pvedaemon, pvestatd, corosync, pmxcfs
- Enterprise repo nag on every `apt update`

**GPU passthrough to LXC was fragile:**
- Required udev hacks (`MODE="0666"` on `/dev/dri`, `/dev/kfd`)
- Manual cgroup2 device allow entries in container config
- Proxmox kernel (Debian Trixie) lagged upstream AMD GPU/ROCm driver support

**Memory management was a fight:**
- Ollama fills its cgroup limit with cached model pages, triggering OOM despite
  reclaimable cache
- Required three separate workarounds: hookscript for `memory.high`, reclaim timer,
  host sysctl tuning
- On bare metal, this problem doesn't exist — no cgroup boundary between Ollama
  and the host page cache

**Ansible provisioning was painful:**
- Every container operation went through `pct exec -- bash -c '...'` — escaping
  hell, no idempotency, no proper change detection
- ~600-line playbook dominated by indirection

### OpenClaw → ZeroClaw in Kubernetes

OpenClaw (CT 101) was the only reason the MS-S1 needed multi-container management,
a firewall, and Proxmox. With a functioning 3-node Talos cluster, the AI agent
workload moves to Kubernetes as ZeroClaw:

| Concern | Proxmox (old) | Kubernetes (new) |
|---------|---------------|------------------|
| Network isolation | Proxmox `.fw` files | CiliumNetworkPolicy (declarative, version-controlled) |
| Persistent storage | LXC rootfs on local-lvm | iSCSI PVC on HL8 NAS + VolSync snapshots |
| Backup | rsync-to-git cron hack | VolSync + Backblaze B2 (existing pipeline) |
| Scheduling | Pinned to MS-S1 | Any of 3 MS-A2 nodes (16C/32T, 32 GB each) |
| Updates | SSH + `pct exec` | Container image via Renovate + Flux |
| Management model | Ansible playbook | GitOps (same as all other workloads) |

With OpenClaw gone, the MS-S1 becomes a single-purpose Ollama inference server.

### Why Ubuntu 26.04 LTS

- **Kernel 7.0** — latest AMD GPU support for RDNA 3.5 (Radeon 8060S)
- **ROCm in official repos** — `apt install rocm`, no external PPAs or manual
  repo configuration
- **TPM-backed full disk encryption** — built into the installer
- **5+5 year support** — LTS through 2031, extended security through 2036
- **sudo-rs** — memory-safe sudo rewrite (Rust)

## Current Architecture

```
Talos Cluster (MS-A2 ×3)
┌──────────────────────────────────────────┐
│  Open WebUI ──→ ollama.securimancy.com   │
│  ZeroClaw   ──→ ollama.securimancy.com   │
│                    │                     │
│  envoy-internal ───┘                     │
│    (TLS termination, wildcard cert)      │
│                                          │
│  ollama-proxy Service ──→ 192.168.5.70   │
│    (EndpointSlice)          :11435       │
│                                          │
│  (CiliumNetworkPolicy on ZeroClaw        │
│   restricts egress, allows Ollama)       │
└──────────────────────────────────────────┘
            │
            ▼
sardior (MS-S1 MAX) — 192.168.5.70
├── nginx :11435 (API key auth) ──→ ollama :11434 (localhost only)
├── node-exporter :9100
├── ollama-exporter :8000
├── nginx-exporter :9113
├── nut-client → themberchaud:3493
└── LUKS + TPM2 auto-unlock (Clevis, PCR7/sha256)

HL8 NAS (TrueNAS SCALE) — 192.168.5.40
  └── iSCSI PVCs for ZeroClaw persistent data
  └── NFS exports for k8s workloads
  └── NUT server (UPS monitoring)
```

sardior is not a Talos/k8s node. Adding it would create a 4-node cluster and
break etcd quorum (even numbers have no advantage over n-1 nodes). It stays as a
standalone inference server that k8s workloads consume over the network.

### Naming Scheme

| IP | Hostname | Hardware | Role |
|----|----------|----------|------|
| 192.168.5.40 | themberchaud | HL8 NAS | TrueNAS SCALE — storage |
| 192.168.5.50 | miirym | MS-A2 #1 | Talos control plane + worker |
| 192.168.5.51 | palarandusk | MS-A2 #2 | Talos control plane + worker |
| 192.168.5.52 | aurinax | MS-A2 #3 | Talos control plane + worker |
| 192.168.5.70 | sardior | MS-S1 MAX | Ollama GPU inference |

All hostnames are Forgotten Realms dragons. sardior is the Ruby Dragon, god of gem
dragons and master of psionics — fitting for a machine whose sole purpose is neural
network inference.

## Ansible Configuration

### Playbook: `ansible/playbooks/ms-s1-configure.yml`

| Section | Tags | What it does |
|---------|------|--------------|
| APT | `apt` | Install ROCm, nginx, Clevis, pciutils, htop, etc. |
| Unattended upgrades | `apt`, `unattended-upgrades` | Auto security updates + auto-reboot at 04:00 |
| Sudo | `system` | Passwordless sudo for `ubuntu` user |
| SSH hardening | `ssh` | Key-only auth, modern ciphers, no root login |
| Disable services | `system` | Mask bluetooth, cups, avahi-daemon |
| GRUB | `grub` | `pcie_aspm=off amdgpu.gttsize=98304 ttm.pages_limit=25165824` |
| System | `system` | Hostname, /etc/hosts, extend LV to full disk, journald cap (2 GB) |
| GPU | `gpu` | Verify ROCm, add user to render+video groups |
| NIC recovery | `nic-recovery` | PCIe bridge reset service (Realtek workaround) |
| Watchdog | `watchdog` | SP5100 TCO module + systemd watchdog (`/dev/watchdog0`) |
| NUT | `nut` | UPS client — graceful shutdown on low battery via themberchaud |
| Sysctls | `sysctl`, `hardening` | Performance tuning + network/kernel hardening |
| Monitoring | `monitoring` | Node exporter (:9100), ollama-exporter (:8000), nginx-exporter (:9113) |
| Ollama | `ollama` | Install, systemd overrides, health check |
| Nginx | `nginx` | API key reverse proxy on :11435 + stub_status on :8080 |
| Models | `models` | Pull initial model set + create nothink variant |
| Validate | `validate` | API health, GPU check, summary |

### Variables: `ansible/inventory/host_vars/sardior/vars.yml`

All Ollama configuration (host, port, keep-alive, context length, flash attention,
ROCm env vars) is parameterized. Model list is maintained in vars.

### Secrets: `ansible/inventory/host_vars/sardior/secrets.sops.yml`

Encrypted with age via sops. Contains `vault_ollama_api_key` and `vault_nut_monitor_password`.

### Usage

```bash
task ansible:init                     # install collections (one-time)
task ansible:ms-s1                    # full run
task ansible:ms-s1:dry-run            # check mode
task ansible:ms-s1 -- --tags ollama   # only ollama config
task ansible:ms-s1 -- --tags models   # only pull models
```

## Installation Procedure

### Phase 1 — Manual (at the box)

1. Enable **Secure Boot** in BIOS (required for TPM PCR7 binding)
2. Flash Ubuntu 26.04 LTS Server onto USB
3. Install on MS-S1 — choose **LUKS full disk encryption** with a passphrase
4. Create user `ubuntu` with sudo
5. Set static IP to `192.168.5.70/24` (or assign fixed IP in UniFi)
6. Enable SSH, then from workstation: `ssh-copy-id -i ~/.ssh/personal.pub ubuntu@192.168.5.70`
7. Bootstrap passwordless sudo: `ssh -t ubuntu@192.168.5.70 'echo "ubuntu ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/ubuntu'`

### Phase 2 — Ansible (from workstation)

8. `task ansible:ms-s1` — installs all packages (including Clevis), extends LVM
   to full disk, configures Ollama, monitoring, hardening, etc.
9. Verify: `curl -H "Authorization: Bearer $API_KEY" http://192.168.5.70:11435/api/tags`

### Phase 3 — TPM LUKS binding (manual, on sardior)

Clevis binding requires interactive passphrase input, so it can't be automated
via Ansible. SSH into sardior and run these commands:

```bash
# 1. Enroll a recovery key (SAVE THE OUTPUT — it won't be shown again)
sudo systemd-cryptenroll --recovery-key /dev/nvme0n1p3

# 2. Bind LUKS to TPM2 PCR7 (will prompt for LUKS passphrase)
#    Note: sha256 bank required — sha1 is empty on this hardware
sudo clevis luks bind -d /dev/nvme0n1p3 tpm2 '{"pcr_bank":"sha256","pcr_ids":"7"}'

# 3. Update initramfs so Clevis can unlock at boot
sudo update-initramfs -u -k all

# 4. Reboot — should unlock automatically via TPM
sudo reboot
```

### TPM Auto-Unlock Notes

- **PCR7** tracks the Secure Boot chain — if you change Secure Boot keys or
  firmware, you'll need to re-bind (the passphrase and recovery key still work)
- After a BIOS update, boot with passphrase and re-run the Clevis bind
  command above to re-bind
- The recovery key is a one-time output — it won't be shown again. Store it
  in your password manager or print it

## Hardening

| Layer | What | Details |
|-------|------|---------|
| SSH | Key-only, no root, modern ciphers | Ed25519/ECDSA keys, ChaCha20/AES-GCM, no password auth |
| Sudo | Passwordless for `ubuntu` | `/etc/sudoers.d/ubuntu` — validated with `visudo` |
| Services | Disabled & masked | bluetooth, cups, cups-browsed, avahi-daemon |
| Sysctls (network) | Hardening + BBR tuning | rp_filter, syncookies, no source route, no redirects |
| Sysctls (kernel) | Restrict ptrace, dmesg | `ptrace_scope=1`, `dmesg_restrict=1`, `sysrq=176`, ASLR |
| Disk encryption | LUKS + TPM2 (Clevis) | PCR7/sha256 auto-unlock, recovery key backup |
| Updates | Unattended upgrades | Security patches auto-applied, auto-reboot at 04:00 |
| Firewall | Ollama localhost-only | External access forced through nginx API key proxy |
| Journald | 2 GB cap, 50 GB keep-free | Prevents log accumulation from filling disk |
| LVM | Auto-extended to full disk | Ubuntu installer defaults to 100 GB — playbook extends to 100% |

## GRUB Parameters

| Parameter | Why |
|-----------|-----|
| `pcie_aspm=off` | Prevents Realtek NICs from dropping off the PCIe bus after sleep/wake |
| `amdgpu.gttsize=98304` | Sets GPU Translation Table to 96 GB — matches the unified memory available to the Radeon 8060S for large model loads |
| `ttm.pages_limit=25165824` | Raises the Translation Table Manager page limit to match the expanded GTT |

## Ollama Systemd Overrides

| Variable | Value | Why |
|----------|-------|-----|
| `OLLAMA_HOST` | `127.0.0.1:11434` | Localhost only — all external access goes through nginx API key proxy |
| `OLLAMA_KEEP_ALIVE` | `24h` | Keep models loaded — inference box is always on |
| `OLLAMA_NUM_PARALLEL` | `1` | Single concurrent request — maximize per-request GPU allocation |
| `OLLAMA_CONTEXT_LENGTH` | `65536` | 64K context window |
| `OLLAMA_LOAD_TIMEOUT` | `30m` | Large models take time to load into VRAM |
| `OLLAMA_FLASH_ATTENTION` | `true` | Flash attention for memory-efficient inference |
| `HSA_ENABLE_SDMA=0` | — | Workaround for ROCm SDMA engine instability on RDNA 3.5 |
| `GPU_MAX_HW_QUEUES=1` | — | Single hardware queue — avoids contention on consumer GPUs |

## Monitoring

Three Prometheus exporters run on sardior, all as native systemd services with no
Docker dependency:

| Exporter | Port | Source | What it exposes |
|----------|------|--------|-----------------|
| **node_exporter** | 9100 | Go binary ([prometheus/node_exporter](https://github.com/prometheus/node_exporter)) | CPU, memory, disk, network, filesystem, systemd unit health |
| **ollama-exporter** | 8000 | Python script (`/opt/ollama_exporter/`) | Models loaded, VRAM per model, GPU %, context length, disk per model, total disk, health |
| **nginx-exporter** | 9113 | Go binary ([nginxinc/nginx-prometheus-exporter](https://github.com/nginxinc/nginx-prometheus-exporter)) | Active connections, requests/sec, accepted/handled connections, reading/writing/waiting |

The node and nginx exporters are downloaded from GitHub releases and tracked by
Renovate for version updates. The ollama-exporter is a pure Python script with
zero external dependencies — it queries Ollama's `/api/ps` and `/api/tags`
endpoints and formats the response as Prometheus metrics. Based on
[akshaypgore/llm-ansible](https://github.com/akshaypgore/llm-ansible).

### Prometheus scrape config

Add these static targets to `kube-prometheus-stack` additional scrape configs:

```yaml
additionalScrapeConfigs:
  - job_name: sardior-node
    static_configs:
      - targets: ["192.168.5.70:9100"]
        labels:
          instance: sardior
  - job_name: sardior-ollama
    static_configs:
      - targets: ["192.168.5.70:8000"]
        labels:
          instance: sardior
  - job_name: sardior-nginx
    static_configs:
      - targets: ["192.168.5.70:9113"]
        labels:
          instance: sardior
```
