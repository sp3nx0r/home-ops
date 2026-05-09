<div align="center">

### Securimancy Homelab

_... managed with Flux, Renovate, and GitHub Actions_

</div>

<div align="center">

[![Talos](https://img.shields.io/badge/talos-v1.13.0-blue?style=for-the-badge&logo=talos&logoColor=white)](https://talos.dev)&nbsp;&nbsp;
[![Kubernetes](https://img.shields.io/badge/kubernetes-v1.35.4-blue?style=for-the-badge&logo=kubernetes&logoColor=white)](https://kubernetes.io)&nbsp;&nbsp;
[![Flux](https://img.shields.io/badge/flux-v2.8.6-blue?style=for-the-badge&logo=flux&logoColor=white)](https://fluxcd.io)&nbsp;&nbsp;
[![Renovate](https://img.shields.io/badge/renovate-enabled-blue?style=for-the-badge&logo=renovatebot&logoColor=white)](https://github.com/sp3nx0r/home-ops/issues?q=label%3Arenovate)

</div>

<div align="center">

[![Status](https://img.shields.io/website?url=https%3A%2F%2Fstatus.securimancy.com&style=for-the-badge&logo=statuspage&label=Status)](https://status.securimancy.com)&nbsp;&nbsp;
[![Last Commit](https://img.shields.io/github/last-commit/sp3nx0r/home-ops?style=for-the-badge&logo=git&logoColor=white&label=Last%20Commit)](https://github.com/sp3nx0r/home-ops/commits/main)&nbsp;&nbsp;
[![Age](https://img.shields.io/github/created-at/sp3nx0r/home-ops?style=for-the-badge&logo=github&label=Repo%20Age)](https://github.com/sp3nx0r/home-ops)

</div>

---

## Overview

This is a mono repository for my home infrastructure and Kubernetes cluster. I try to adhere to Infrastructure as Code (IaC) and GitOps practices using tools like [Ansible](https://www.ansible.com/), [Kubernetes](https://kubernetes.io/), [Flux](https://github.com/fluxcd/flux2), and [Renovate](https://github.com/renovatebot/renovate).

---

## Kubernetes

My Kubernetes cluster is deployed with [Talos](https://www.talos.dev) on three bare-metal nodes. This is a hyper-converged setup where all nodes are control-plane members and run workloads. A separate [TrueNAS SCALE](https://www.truenas.com/truenas-scale/) server provides NFS storage and backups, managed via Ansible.

There is a template over at [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template) if you want to try and follow along with some of the practices I use here.

### Core Components

- **[cilium](https://github.com/cilium/cilium)** - eBPF-based CNI, replacing kube-proxy, with L2 announcement for LoadBalancer IPs.
- **[envoy-gateway](https://github.com/envoyproxy/gateway)** - Gateway API implementation for ingress traffic management.
- **[cert-manager](https://github.com/cert-manager/cert-manager)** - Automated SSL/TLS certificates via Let's Encrypt with Cloudflare DNS-01 validation.
- **[external-dns](https://github.com/kubernetes-sigs/external-dns)** - Two instances: one syncing public DNS to Cloudflare, another syncing private DNS to UniFi via [webhook](https://github.com/kashalls/external-dns-unifi-webhook).
- **[cloudflared](https://github.com/cloudflare/cloudflared)** - Cloudflare Tunnel for secure external access without exposing ports.
- **[sops](https://github.com/getsops/sops)** - Secrets encrypted with age, decrypted by Flux at reconciliation time.
- **[spegel](https://github.com/spegel-org/spegel)** - Stateless cluster-local OCI image mirror for faster pulls and resilience.
- **[reloader](https://github.com/stakater/Reloader)** - Automatic rolling restarts when ConfigMaps or Secrets change.

### GitOps

[Flux](https://github.com/fluxcd/flux2) watches the cluster in my [kubernetes](./kubernetes/) folder and makes changes based on the state of this Git repository.

The way Flux works for me here is it will recursively search the `kubernetes/apps` folder until it finds the most top level `kustomization.yaml` per directory and then apply all the resources listed in it. That `kustomization.yaml` will generally only have a namespace resource and one or many Flux kustomizations (`ks.yaml`). Under the control of those Flux kustomizations there will be a `HelmRelease` or other resources related to the application.

[Renovate](https://github.com/renovatebot/renovate) watches my **entire** repository looking for dependency updates, when they are found a PR is automatically created. When PRs are merged Flux applies the changes to my cluster.

### Directories

```sh
📁 kubernetes
├── 📁 apps           # applications
│   ├── 📁 cert-manager    # certificate management
│   ├── 📁 default         # random tools that don't deserve isolation
│   ├── 📁 flux-system     # flux operator & instance
│   ├── 📁 kube-system     # cilium, coredns, spegel, reloader, etc.
│   ├── 📁 media           # plex, tautulli, arr stack
│   ├── 📁 network         # envoy-gateway, cloudflared, external-dns
│   └── 📁 o11y            # prometheus, grafana, alertmanager, unpoller
├── 📁 bootstrap      # bootstrap resources
└── 📁 flux           # flux system configuration
📁 talos              # talos machine configuration
📁 ansible            # TrueNAS NAS configuration
```

---

## DNS

Two instances of [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) are running in the cluster. One syncs private DNS records to my UniFi Dream Machine using [external-dns-unifi-webhook](https://github.com/kashalls/external-dns-unifi-webhook), while the other syncs public DNS to Cloudflare. This is managed by creating `HTTPRoute` resources with the appropriate `envoy-internal` or `envoy-external` gateway references.

---

## Observability

The monitoring stack is built on [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) with a standalone [Grafana](https://github.com/grafana/grafana) deployment. Dashboards are organized by folder (Kubernetes, Network, Observability, System, UniFi, Flux) using sidecar provisioning with folder annotations.

- **Prometheus** - Metrics collection with 14-day retention
- **Alertmanager** - Critical alerts routed to Discord
- **Grafana** - Dashboards for Cilium, Envoy, Flux, External DNS, Node Exporter, Cert Manager, UniFi, and more
- **Unpoller** - UniFi network metrics exporter
- **TrueNAS Exporter** - NAS metrics via WebSocket API
- **Flux Notifications** - Error-level reconciliation events sent to Discord

---

## Hardware

| Device | Num | OS Disk | RAM | OS | Function |
|---|---|---|---|---|---|
| MinisForum MS-A2 | 3 | 1TB NVMe | 32GB | Talos | Kubernetes (control-plane + worker) |
| 45Drives HL8 | 1 | 5x4TB RAIDZ1 | 32GB | TrueNAS SCALE | NFS + Backups |
| UniFi Dream Machine | 1 | - | - | - | Router & NVR |
| UniFi USW Aggregation | 1 | - | - | - | SFP Data Plane |
| CyberPower UPS | 1 | - | - | - | UPS |

---

## Cloud Dependencies

| Service | Use | Cost |
|---|---|---|
| [Cloudflare](https://www.cloudflare.com/) | Domain, DNS, and Tunnel | Free |
| [Backblaze B2](https://www.backblaze.com/cloud-storage) | Offsite backups | ~$5/mo |
| [Bitwarden](https://bitwarden.com/) | Password management | ~$4/mo |
| [GitHub](https://github.com/) | Repository hosting and CI/CD | Free |
| [Discord](https://discord.com/) | Alert notifications | Free |
| [Let's Encrypt](https://letsencrypt.org/) | SSL/TLS certificates | Free |
| | | **Total: ~$9/mo** |

---

## Thanks

Big shout out to [onedr0p](https://github.com/onedr0p/home-ops) and the [cluster-template](https://github.com/onedr0p/cluster-template) that this repo was bootstrapped from, as well as the [Home Operations](https://discord.gg/home-operations) Discord community. Check out [kubesearch.dev](https://kubesearch.dev/) for ideas on how to deploy applications in your own cluster.
