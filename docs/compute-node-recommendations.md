# Compute Node Recommendations — Replacing the ThinkServer TS440

> Goal: Replace the aging Lenovo ThinkServer TS440 (4C/8T Xeon E3-1245 v3, 32 GB
> DDR3 ECC, failing DIMM) with modern mini PCs running Talos Linux for Kubernetes.
> Storage is offloaded to the HL8 NAS.

## Current State

The ThinkServer runs 4 k3s VMs on a single host — no HA, single failure domain:

| VM | Role | vCPU | RAM |
|----|------|------|-----|
| k3s-master-0 | Control plane (no workloads) | 2 | 8 GB |
| k3s-worker-0 | Worker | 2 | 7 GB |
| k3s-worker-1 | Worker | 2 | 7 GB |
| k3s-worker-2 | Worker | 2 | 7 GB |
| **Total allocated** | | **8 vCPU** | **29.5 GB** |
| **Host hardware** | | **4C/8T** | **32 GB** |

Plus a Docker container (tor-bridge) running on the Proxmox host itself.

Problems:
- Single failure domain — host dies, everything dies (and it has been dying)
- Overcommitted — 8 vCPUs on 4C/8T with no headroom
- k3s master wastes 2 vCPU + 8 GB on control plane with no workloads scheduled
- No HA — single control plane node, etcd has no quorum redundancy
- Aging hardware with failing RAM (see proxmox-soft-lockup-disk-controller.md)

## Target Architecture: 3-Node Talos Cluster

### Why 3 Nodes (Not 4+)

**etcd quorum requires an odd number of control plane nodes for HA:**

| CP Nodes | Quorum | Tolerate | HA? |
|----------|--------|----------|-----|
| 1 | 1 | 0 failures | No |
| 2 | 2 | 0 failures | No (split brain risk) |
| 3 | 2 | 1 failure | **Yes** |
| 5 | 3 | 2 failures | Overkill for homelab |

**Talos supports `allowSchedulingOnControlPlanes: true`**, which removes the
`NoSchedule` taint from control plane nodes. All 3 nodes run etcd + kube-apiserver
**and** schedule regular workload pods. No wasted "master-only" nodes.

```yaml
# Talos machine config
cluster:
  allowSchedulingOnControlPlanes: true
```

This is the standard homelab pattern — onedr0p's 3 ASUS NUCs run exactly this way.

### Why Talos over k3s

| | k3s (current) | Talos |
|---|---|---|
| Runs on | General-purpose Linux (Ubuntu, Debian) | **Is** the OS — purpose-built for k8s |
| OS maintenance | apt update, SSH, shell access | None — immutable, API-driven config |
| Config management | Ansible/SSH into each node | Declarative YAML, version-controlled |
| etcd | Optional (default SQLite/kine) | Always etcd, built for HA |
| Shell access | Yes (SSH) | **No shell, no SSH** — all via talosctl API |
| Security surface | Full Linux userspace | Minimal — no packages, no shell, no users |
| Mixed CP + worker | Possible (remove taints) | First-class (`allowSchedulingOnControlPlanes`) |
| Upgrades | Manual or Ansible | `talosctl upgrade` — atomic, rollback-safe |
| Fits GitOps model | Partially | Fully — aligns with Flux/GitOps repo |

k3s can also run 3 mixed nodes, but Talos eliminates the OS management layer entirely.
No more maintaining Ubuntu, no more Ansible playbooks for node config. The entire node
state is a YAML file in your repo.

### Cluster Topology

```
┌─────────────┐  ┌─────────────┐  ┌─────────────┐
│   node-0    │  │   node-1    │  │   node-2    │
│  MS-A2 #1   │  │  MS-A2 #2   │  │  MS-A2 #3   │
│             │  │             │  │             │
│ CP + worker │  │ CP + worker │  │ CP + worker │
│ etcd member │  │ etcd member │  │ etcd member │
│ 16C/32T     │  │ 16C/32T     │  │ 16C/32T     │
│ 32 GB RAM   │  │ 32 GB RAM   │  │ 32 GB RAM   │
└──────┬──────┘  └──────┬──────┘  └──────┬──────┘
       │    10GbE SFP+  │               │
       └────────┬───────┘───────────────┘
                │
         ┌──────┴──────┐
         │   HL8 NAS   │   ← iSCSI (PVCs) + NFS/SMB shares
         │  TrueNAS    │
         │  RAIDZ1/Z2  │
         └─────────────┘

Existing:
┌─────────────┐
│   MS-S1     │   ← AI workloads (already owned)
│  (separate) │
└─────────────┘
```

Lose 1 node → etcd quorum holds (2/3), pods reschedule to surviving 2 nodes.
Lose 2 nodes → cluster is down.

## Recommended Hardware: 3x MinisForum MS-A2

### Why the MS-A2

The MS-A2 fits naturally alongside the existing MS-S1 and is the best current option
for a Talos k8s node:

- **16 uniform Zen 4 cores** — no P+E core scheduling headaches for hypervisors/k8s.
  The scheduler treats all cores equally, which matters for consistent pod performance.
- **Dual 10GbE SFP+** — direct high-speed link to the HL8 NAS for storage I/O
- **Same 1.4L form factor as MS-01** — compact, stackable
- **Available** — unlike the MS-01 which is sold out everywhere

### CPU Selection: Ryzen 9 7945HX

| | R7 7745HX | **R9 7945HX** | R9 8945HX | R9 9955HX |
|---|---|---|---|---|
| **Cores / Threads** | 8C/16T | **16C/32T** | 16C/32T | 16C/32T |
| **Architecture** | Zen 4 | **Zen 4** | Zen 4 (rebadge) | Zen 5 |
| **Process** | 5nm | **5nm** | 5nm | 4nm |
| **Base / Boost** | 3.6 / 5.1 GHz | **2.5 / 5.4 GHz** | 2.5 / 5.4 GHz | 2.5 / 5.4 GHz |
| **L3 Cache** | 32 MB | **64 MB** | 64 MB | 64 MB |
| **TDP** | 55W | **55W** | 55W | 55W |
| **MS-A2 barebone** | ~$439 | **$559** | ~$609 | ~$800-840 |

**7945HX is the pick:**
- 16C/32T with 64 MB L3 — identical core count and cache to the 8945HX and 9955HX
- The 8945HX is a literal rebadge of the 7945HX (same silicon) but $50 more
- The 9955HX (Zen 5) is ~7% faster but ~$240 more per node ($720 across 3 nodes)
- The 7745HX saves $120/node but halves the cores and cache — not worth it
- At $559 barebone, the 7945HX is the price/performance sweet spot

### MinisForum MS Lineup Comparison

| | **MS-01** | **MS-A2** | **MS-02 Ultra** |
|---|---|---|---|
| **CPU** | Intel i9-13900H (14C/20T) | AMD Ryzen 9 7945HX (16C/32T) | Intel Ultra 9 285HX (24C/24T) |
| **Architecture** | Raptor Lake (mixed P+E) | **Zen 4 (uniform cores)** | Arrow Lake (mixed P+E) |
| **RAM max** | 64 GB DDR5 (2 slots) | 96 GB DDR5 (2 slots) | **256 GB DDR5 (4 slots, ECC)** |
| **10GbE** | 2x SFP+ | 2x SFP+ | **2x 25G SFP+** + 1x 10G RJ45 |
| **2.5GbE** | 2x Intel | 1x Intel + 1x Realtek | 1x RJ45 |
| **M.2 slots** | 3 (PCIe 3.0/4.0 mix) | 3 (PCIe 4.0) | **4 (PCIe 4.0)** |
| **PCIe slot** | x16 (PCIe 4.0) | x8 (PCIe 4.0) | **x16 (PCIe 5.0)** |
| **USB4/TB4** | Yes | **No** | Yes |
| **GPU support** | Single-slot | Single-slot | **Dual-slot desktop** |
| **PSU** | External brick | External brick | **Internal 350W** |
| **Volume** | 1.4L | 1.4L | 4.8L (~3.5x larger) |
| **Barebone price** | ~$440-480 | **$559** | ~$1,199 |
| **Availability** | **Sold out** | Available | Available |

**MS-01**: Great value but effectively discontinued — can't buy 3 of them.

**MS-A2**: Best for k8s nodes. Uniform cores, 16C/32T, dual 10GbE, compact. The
lack of USB4/TB4 doesn't matter for a headless Talos node.

**MS-02 Ultra**: Workstation-class overkill. 256 GB ECC RAM and 25GbE are amazing
but the 4.8L chassis, $1,200 price, and 350W PSU make it a different class of machine.
Better suited as a single powerful Proxmox host than a k8s node.

### Configuration: Pre-Configured 32 GB + 1 TB

Going with the MinisForum **pre-configured 32 GB RAM + 1 TB NVMe** option at **$919/node**.

| Component | Spec | Price |
|-----------|------|-------|
| **MS-A2 pre-configured** | R9 7945HX, 32 GB DDR5, 1 TB NVMe | **$919** |

**Why pre-configured over barebone + self-source:**
- Barebone ($559) + 2x 32 GB RAM (~$152) + 500 GB NVMe ($176) = $887 — only $32
  less, and that assumes RAM stays at ~$76/stick (DDR5 SO-DIMM prices are inflated)
- Pre-configured includes 1 TB NVMe (vs 500 GB) — headroom for local scratch,
  container layers, and future services (e.g. object-storage components)
- Trade-off: 32 GB per node instead of 64 GB, but upgradeable

#### RAM Upgrade Path

The MS-A2 has **2 SO-DIMM slots**. The pre-configured ships with 1x 32 GB stick,
leaving one slot empty. When DDR5 prices normalize, add a second stick:

| Upgrade | Part | Result |
|---------|------|--------|
| +32 GB (1 stick) | Crucial CT32G56C46S5 DDR5-5600 SO-DIMM | 64 GB/node |
| +48 GB (swap both) | 2x 48 GB DDR5-5600 SO-DIMM | 96 GB/node (max) |

**What to match when buying the second stick:**
- DDR5 **SO-DIMM** (262-pin) — not desktop DIMM, not DDR4
- 4800 MHz or 5600 MHz (both work; the board clocks to whatever is installed)
- 1.1V
- **Non-ECC unbuffered** — the MS-A2 does not support ECC

### 3-Node Cluster Totals

| Resource | Per Node | 3-Node Cluster | vs ThinkServer |
|----------|----------|----------------|----------------|
| **CPU** | 16C/32T | **48C/96T** | **12x cores** |
| **RAM** | 32 GB DDR5 (→64 GB) | **96 GB** (→192 GB) | **3x capacity** (→6x) |
| **Storage** | 1 TB NVMe | 3 TB local | + HL8 NAS over 10GbE |
| **Network** | 2x 10G + 2x 2.5G | 6x 10G + 6x 2.5G | 10GbE (vs 1GbE) |
| **Failure domains** | 1 | **3** | HA (vs none) |
| **Idle power** | ~20-30W | **~70-90W** | Similar to ThinkServer |
| **Single-thread** | ~3,200 (Passmark) | — | ~2x faster per core |

## Budget Options

### Start with 2 Nodes (~$1,838)

A 2-node cluster runs but doesn't have HA:
- etcd with 2 members requires both for quorum — lose 1 and the cluster stalls
- Workloads still split across 2 nodes (32C/64T, 64 GB)
- Add the 3rd node later for HA

This is viable as a stepping stone but not recommended as a long-term topology.

## Networking Plan

### Unified UniFi LAN (single routing domain)

There is **one** network: your regular UniFi Ethernet LAN, with the **USW
Aggregation** trunked into it via **SFP** (same L2/L3 domain as the rest of the
house). Talos nodes and the HL8 NAS attach at **10 Gbps** with **SFP+ DACs** to the
aggregation switch; traffic to the internet and the rest of the LAN reaches the
**UDM** over the normal path (in your layout, **2.5G** uplink to the UDM).

So you do **not** maintain two parallel “control planes” (a separate isolated 10G
island vs. the home LAN). The 10G links are the fast access layer into one network,
not a second disconnected fabric.

| Role | How it fits |
|------|-------------|
| **Router / gateway** | UDM (e.g. 192.168.5.1 on the Talos/compute VLAN) — DHCP, firewall, internet |
| **10G access** | USW Aggregation — Talos nodes + HL8 NAS on SFP+ |
| **LAN integration** | Aggregation patched into your existing UniFi switches via SFP |
| **WAN path** | Uplink toward UDM at 2.5G (bottleneck only for internet/WAN, not LAN-to-LAN at 10G) |

The MS-A2 **2.5GbE RJ45** ports remain available for out-of-band setup, a slow-path
fallback, or future use; primary cluster + NFS throughput uses **SFP+** into the
aggregation switch.

### Physical Cabling

```
UDM (gateway)
    │
    │  2.5G uplink (path to router / internet for devices that route via UDM)
    │
Existing UniFi switches (your regular Ethernet network)
    │
    │  SFP trunk — USW Aggregation is part of this fabric, not a separate island
    │
USW-Aggregation (8× SFP+)
    │  │  │  │
    │  │  │  │  10GbE SFP+ DAC cables (nodes + NAS)
    │  │  │  │
    │  │  │  └─── MS-A2 node-2 (SFP+)
    │  │  └────── MS-A2 node-1 (SFP+)
    │  └───────── MS-A2 node-0 (SFP+)
    └──────────── HL8 NAS (Mellanox ConnectX-3 PCIe NIC, SFP+)

Elsewhere on the same LAN (RJ45 as needed):
    MS-S1 ───→ UniFi switch / UDM (no requirement for SFP+)
```

Second **SFP+** ports on the MS-A2 units stay free for expansion (extra uplink,
direct link, or future gear).

### Switch Choice

| | **Mikrotik CRS305** | **UniFi USW-Aggregation** |
|---|---|---|
| SFP+ ports | 4 (exact fit) | 8 (room to grow) |
| RJ45 uplink | 1× 1GbE | None |
| Management | RouterOS/SwOS | UniFi controller |
| Fanless | Yes | Yes |
| Price | ~$140 | **$269** |

USW-Aggregation is the pick if you run UniFi gear. 8 ports means you can add the
MS-S1 later (with a 10G NIC) or a second NAS without replacing the switch. The
Mikrotik CRS305 saves $130 but fills all 4 ports on day one — zero headroom.

### HL8 NAS 10G NIC

The HL8 doesn't ship with SFP+. Add a **Mellanox ConnectX-3** (MCX311A-XCAT) in the
PCIe slot — ~$15-25 used on eBay, single SFP+ port, works out of the box with
TrueNAS/Linux. The HL8's PCIe slot is full-height, so the card fits without adapters.

### IP Assignments

Use **one subnet** for the Talos nodes (example **`192.168.5.0/24`**) on the
interfaces you bring up for production. A common pattern: **primary IP on the
SFP+ interface** so management, Kubernetes, and NFS to the HL8 all use the 10G
path through the aggregation switch. The RJ45 NIC can stay unnumbered until you
need a backup path.

| Device | Example IP (LAN) | Notes |
|--------|------------------|--------|
| UDM | 192.168.5.1 | Default gateway (Talos/compute network) |
| node-0 | 192.168.5.50 | Prefer on SFP+ (`enp…`) |
| node-1 | 192.168.5.51 | |
| node-2 | 192.168.5.52 | |
| HL8 NAS | 192.168.5.40 | NFS/SMB on same IP (10G path when clients use this address) |
| MS-S1 | 192.168.5.70 | RJ45 to UniFi LAN (Ollama / sardior; same subnet as nodes when unified) |

From your laptop, `talosctl` / `kubectl` target the nodes at `192.168.5.50`–`.52`.
Inter-node and NFS traffic flows at **10 Gbps** on the aggregation switch when
source and destination use the SFP+ path.

### How Routing Works

Single default route **via the UDM** on whichever interface carries the node’s LAN
IP (typically SFP+). The kernel sends traffic by destination: same subnet ARPs on
the 10G side; internet-bound traffic goes to `192.168.5.1` over the same unified LAN.

The **2.5G uplink to the UDM** limits **WAN** throughput, not east–west traffic
between nodes and NAS at 10G on the aggregation switch.

### Talos Machine Config (Per Node)

Example with **one primary interface** (SFP+) on the shared LAN:

```yaml
machine:
  network:
    hostname: node-0
    interfaces:
      - interface: enp6s0f0        # SFP+ 10GbE — primary on unified LAN
        addresses:
          - 192.168.5.50/24
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.5.1    # UDM (Talos / compute VLAN)
      # Optional: second NIC for staging / fallback (omit addresses if unused)
      # - interface: enp1s0
```

Interface names (`enp6s0f0`, etc.) vary — use `talosctl get links` after first boot.
Adjust per node (node-1 → `192.168.5.51`, node-2 → `192.168.5.52`).

If you prefer **dual-homed** nodes (addresses on both RJ45 and SFP+), use policy
routing or a single address on one interface to avoid asymmetric routing; the
simplest ops story is **one IP on SFP+** as above.

### Kubernetes / CNI Configuration

**Persistent volumes (block):** **democratic-csi** with the **TrueNAS API iSCSI**
driver (`freenas-api-iscsi` in the chart) — a StorageClass (e.g. `iscsi`) provisions
**zvols** on the HL8 and presents them over iSCSI. That is the path for workload PVCs
that need a real block device. iSCSI traffic uses the same IP path to TrueNAS as the
rest of the stack (10G when nodes and NAS are on the aggregation fabric). Talos
expects `iscsi-tools` and host `iscsiadm` paths as in the democratic-csi node settings.

**NAS file access:** TrueNAS **built-in NFS** (and SMB) shares on datasets — used for
general file-store access, backups, media libraries, or mounts that are **not** the
Kubernetes NFS CSI `nfs-subprovisioner` pattern. This setup does **not** use an
**NFS StorageClass**; PVCs for cluster storage go through **democratic-csi / iSCSI**.

**Cilium / Flannel CNI** — configure the CNI to bind pod-to-pod mesh traffic to the
10G interface so inter-node pod communication uses SFP+ instead of the 2.5GbE:

```yaml
# Cilium Helm values (example)
ipam:
  mode: kubernetes
devices:
  - enp6s0f0                   # SFP+ interface for pod traffic
```

### TrueNAS HL8 Network Config

On the HL8, the **Mellanox SFP+** NIC carries traffic to the Talos nodes at 10G via
USW Aggregation. You can use **one IP** on the LAN (e.g. `192.168.5.40/24`) on the
interface that is your preferred primary (often the SFP+ port once cabled), with
default gateway / DNS pointed at the UDM. Expose **NFS/SMB shares** from TrueNAS
on that address for LAN file access (bind addresses / firewall rules as you prefer).
**iSCSI** extents for democratic-csi are configured in TrueNAS and driven via the
API (`freenas-api-iscsi` driver config secret).

If you keep **both** onboard RJ45 and SFP+ active, give them **different subnets**
or use a single active path for the shared IP to avoid duplicate-address confusion;
the simplest homelab setup is **one address on SFP+** for TrueNAS + NFS + UI, with
SMB from LAN clients using the same IP (traffic crosses the UniFi fabric at 10G
when the client path supports it).

## Storage Architecture (with HL8 NAS)

With Talos, local storage is minimal (boot + ephemeral). Persistent data lives on
the HL8 NAS:

| Storage Type | Where | Use |
|-------------|-------|-----|
| **Boot/OS** | Local NVMe on each MS-A2 | Talos OS, ephemeral pods |
| **Persistent volumes** | HL8 via **democratic-csi** (iSCSI zvols) | Databases, app data (PVCs) |
| **File shares** | HL8 TrueNAS **NFS/SMB** (built-in shares) | Media, backups, LAN access to datasets |
| **Object / blob storage** | S3-compatible on-cluster (*planned*) — **Garage**, **MinIO**, or **SeaweedFS** | Buckets, app-native object APIs, large blobs, backup targets |

**No Rook-Ceph for now.** Block PVCs stay on **TrueNAS iSCSI via democratic-csi**;
file access stays on TrueNAS NFS/SMB. When you need S3-style storage, add one of the
object layers above (they're a different trade-off than onedr0p's Rook-Ceph-on-NUC
local NVMe pattern).

## Migration Plan

1. **Order 3x MS-A2** (pre-configured 32 GB + 1 TB)
2. **Install Talos** on all 3 nodes using `talosctl gen config` with
   `allowSchedulingOnControlPlanes: true`
3. **Bootstrap the cluster** — `talosctl bootstrap` on node-0
4. **Install Flux** and point it at the homelab repo's kubernetes directory
5. **Configure democratic-csi** (TrueNAS API iSCSI) and TrueNAS shares for file access
6. **Migrate workloads** from k3s → Talos (redeploy via Flux/GitOps, not live migration)
7. **Decommission ThinkServer** — pull remaining drives, power it down for good

## Physical Setup: Wire Shelf

A full 19" server rack is overkill — nothing in this setup is rack-mountable (the HL8
is a desktop chassis, the MS-A2/MS-S1 are mini PCs). A simple 2-tier wire shelf holds
everything cleanly and costs $15-25.

### Device Dimensions

| Device | W × D × H (in) | Weight | Notes |
|--------|-----------------|--------|-------|
| MS-A2 (×3) | 7.7 × 7.4 × 1.9 | 3.7 lb | Same footprint as MS-01 |
| MS-S1 (×1) | 8.7 × 8.1 × 3.0 | 6.2 lb | Larger, runs hottest (320W PSU) |
| USW-Aggregation | ~11 × 5 × 1.7 | ~2 lb | Fanless 10G |
| Power bricks (×4) | ~6 × 3 × 1.5 ea | — | External, need space behind/below |

### Shelf Spec

**Target: 2-tier wire shelf, 18" × 12" minimum**

- Width: 18" fits 2 devices side by side (widest pair: MS-S1 + MS-A2 = 16.4")
- Depth: 12" gives 8" for the deepest device + 4" for cables/airflow behind
- Tier spacing: 6"+ between shelves for airflow
- Alternative: 24" × 12" for more breathing room and space for power bricks

Search for "2-tier wire shelf 18×12" or "kitchen counter organizer rack" on Amazon —
Simple Houseware, DecoBros, and similar brands all make these for $15-25.

### Layout

```
              18"
    ┌─────────────────────┐
    │  MS-A2    MS-A2     │  ← Top tier
    │        [USW-Agg]    │     2 compute nodes + aggregation switch
    │                     │
    ├─────────────────────┤  ~6" clearance (airflow)
    │  MS-S1    MS-A2     │  ← Bottom tier
    │                     │     AI node + 3rd compute node
    └─────────────────────┘
              12" deep
           ← front ───── back (cables) →

    Power bricks underneath shelf or tucked behind
```

**Bottom tier:** MS-S1 (heaviest, most heat from 320W PSU) + third MS-A2.
Side by side: 8.7" + 7.7" = 16.4" — fits in 18" with spacing.

**Top tier:** 2x MS-A2 + USW-Aggregation.
Side by side: 7.7" + 7.7" = 15.4" — switch fits in remaining space.

**HL8 NAS** sits separately on/under the desk — it's a full desktop tower chassis.

### Airflow Tips

- Keep at least 1" between devices for convection
- Orient all devices with exhaust vents facing the same direction (toward back)
- Don't stack devices directly on top of each other without a shelf tier between them
- Rubber feet or shelf liner prevents sliding on wire shelves
- If thermals are a concern in a closed space, a $10 USB fan pointed at the shelf
  handles it

## UPS / Power Protection

### Power Budget

| Device | Idle | Typical Load | Peak |
|--------|------|--------------|------|
| MS-A2 (×3) | ~25-30W each | ~80-100W each | ~150W each |
| MS-S1 (×1) | ~15W | ~60-95W | ~160W |
| HL8 NAS (5-8 drives) | ~50-70W | ~80-100W | ~120W |
| USW-Aggregation | ~15W | ~15W | ~20W |
| USW-Flex-2.5G-8 | ~10W | ~10W | ~14W |
| **Total** | **~165-205W** | **~325-420W** | **~614W** |

Day-to-day the homelab hovers around **200-250W** (mostly idle / light load). Sustained
max load across everything simultaneously is rare.

### UPS Requirements

- **Capacity:** 1000-1500VA / 600-1000W — headroom above typical draw with peak margin
- **Type:** Line-interactive with AVR (automatic voltage regulation)
- **Output:** Pure sine wave — required. The HL8's 80+ Gold PSU and MS-A2 power bricks
  have active PFC and can malfunction on simulated sine wave
- **Interface:** USB HID — for NUT (Network UPS Tools) graceful shutdown
- **Runtime target:** 10-15 minutes at ~200W idle to shut down cleanly

### Recommended Models

| UPS | Capacity | Type | Price |
|-----|----------|------|-------|
| CyberPower CP1000PFCLCD | 1000VA / 600W | Line-interactive, AVR, pure sine | ~$130 |
| **CyberPower CP1500PFCLCD** | **1500VA / 1000W** | **Line-interactive, AVR, pure sine** | **~$200** |
| APC BR1500MS2 | 1500VA / 900W | Line-interactive, AVR, pure sine | ~$230 |

The **CP1500PFCLCD** is the sweet spot — 1000W handles the full load with margin,
~15-20 min runtime at typical idle (~200W), and the LCD shows real-time wattage.
The 1000VA model works but leaves less headroom if everything spikes.

### NUT Integration for Graceful Shutdown

Plug the UPS USB cable into the **HL8 NAS**. TrueNAS has NUT built in — configure it
as the NUT server. The Talos nodes run a NUT client to monitor battery status and
trigger graceful shutdown before power runs out.

**TrueNAS (NUT server):** Services → UPS → enable, set as "Master", configure
shutdown command and low-battery threshold.

**Talos (NUT client):** Add `siderolabs/nut-client` to your system extensions in the
Image Factory schematic alongside the other extensions. Configure via machine config:

```yaml
# Additional extension for Talos image
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/amd-ucode
      - siderolabs/realtek-firmware
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
      - siderolabs/nfs-utils
      - siderolabs/nut-client       # UPS monitoring
```

**Shutdown sequence on power loss:**
1. UPS switches to battery, NUT server (TrueNAS) detects it
2. NUT clients (Talos nodes) receive low-battery signal
3. Talos nodes drain pods and shut down gracefully
4. TrueNAS exports ZFS pools and shuts down last
5. UPS powers off

## Purchase Plan

| # | Item | Qty | Unit Price | Total |
|---|------|-----|------------|-------|
| 1 | MinisForum MS-A2 (R9 7945HX, 32 GB, 1 TB NVMe) | 3 | $919 | $2,757 |
| 2 | UniFi USW-Aggregation (8-port 10G SFP+) | 1 | $269 | $269 |
| 3 | 10G SFP+ DAC cables (3× 0.5m + 1× 3m) | 4 | ~$10-15 | ~$50 |
| 4 | Mellanox ConnectX-3 SFP+ NIC (used, for HL8) | 1 | ~$20 | ~$20 |
| 5 | CyberPower CP1500PFCLCD UPS | 1 | ~$200 | ~$200 |
| 6 | 2-tier wire shelf (18" × 12") | 1 | ~$20 | ~$20 |
| | **Total** | | | **~$3,316** |
| | | | | |
| | *Future: RAM upgrade (3x 32 GB SO-DIMM)* | *3* | *~$76* | *~$228* |
