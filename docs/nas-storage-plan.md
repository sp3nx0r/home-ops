# HL8 NAS Storage Plan

> Platform: 45Drives HL8 (8 bays, 1 PCIe slot)
> OS: TrueNAS SCALE
> Network: Mellanox ConnectX-3 SFP+ (192.168.5.40)

## Phase 1 — Temporary: 5× 4TB Drives

Interim config using existing drives from the old homelab. Data is backed up to an
external SSD via rsnapshot — recovery is acceptable if a drive fails.

### Pool Layout

```
tank (RAIDZ1)
└── raidz1-0: disk0, disk1, disk2, disk3, disk4
```

| | Value |
|---|---|
| **Drives** | 5× 4TB (existing) |
| **Layout** | Single RAIDZ1 vdev |
| **Raw** | 20TB |
| **Usable** | ~16TB |
| **Parity** | 1 drive |
| **Failure tolerance** | 1 drive |

### Why RAIDZ1 is acceptable here

- **Temporary** — this pool will be destroyed when permanent drives arrive
- **4TB drives resilver fast** — hours, not days. The rebuild risk that makes RAIDZ1
  dangerous with 18TB+ drives doesn't apply here.
- **Data is expendable** — backed up to external SSD, old homelab is off
- **Maximizes usable space** — 16TB vs 12TB (RAIDZ2) or 8TB (mirrors)

### Dataset Layout (Temporary)

Keep it simple — mirror the permanent layout structure so migration is just
re-exporting the same paths from the new pool.

```
tank/
├── backups/         # rsnapshot, Velero, etcd snapshots
├── media/           # Plex, *arr apps
├── homelab/
│   └── k8s-exports/ # NFS PVCs for the Talos cluster
└── scratch/         # temp workspace
```

| Dataset | compression | recordsize | atime | sync | Notes |
|---------|-------------|------------|-------|------|-------|
| `tank/backups` | zstd-3 | 1M | off | standard | Large sequential writes |
| `tank/media` | lz4 | 1M | off | standard | Already-compressed media |
| `tank/homelab/k8s-exports` | zstd-3 | 128K | off | standard | Mixed k8s PVC I/O |
| `tank/scratch` | lz4 | 128K | off | disabled | Expendable temp data |

### NFS Exports

| Export Path | Allowed Network | Purpose |
|-------------|-----------------|---------|
| `/mnt/tank/homelab/k8s-exports` | 192.168.5.0/24 | Talos cluster PVCs |
| `/mnt/tank/media` | 192.168.5.0/24 | Media clients (Plex, etc.) |
| `/mnt/tank/backups` | 192.168.5.0/24 | Cluster backup targets |

### Automation

Pool creation is manual (TrueNAS UI). Everything else is managed by Ansible:

```bash
task ansible:configure
```

See `ansible/README.md` for full prerequisites, manual steps, and tag usage.

---

## Phase 2 — Permanent: 8× 18–20TB Drives

Target configuration once drives are purchased. Wipe the temporary pool and rebuild.

### Drive Selection

| Size | $/TB | Rebuild Time | Notes |
|------|------|-------------|-------|
| 12TB | ~$12–15/TB | ~10–16 hrs | Best value, lower density |
| 16TB | ~$13–16/TB | ~14–24 hrs | Good balance |
| **18TB** | **~$14–18/TB** | **~18–30 hrs** | **Sweet spot — recommended** |
| 20TB | ~$16–20/TB | ~20–36+ hrs | Best density, longest rebuilds |
| 22TB | ~$18–22/TB | ~24–48 hrs | What onedr0p runs (mirrored, HL15) |

Recommended models:
- **Seagate Exos X18 18TB** — enterprise, best cost efficiency, louder
- **Seagate Exos X20 20TB** — max density, enterprise
- **WD Red Pro 20TB** — NAS-grade, quieter, more expensive

### Pool Layout: 2× 4-Drive RAIDZ2

```
tank
├── raidz2-0: disk0, disk1, disk2, disk3
└── raidz2-1: disk4, disk5, disk6, disk7
```

| | Value |
|---|---|
| **Drives** | 8× 18TB (example) |
| **Layout** | 2× 4-drive RAIDZ2 (striped) |
| **Raw** | 144TB |
| **Usable** | ~72TB |
| **Parity** | 2 drives per vdev |
| **Failure tolerance** | 2 drives per vdev (4 total if failures are split) |

### Why 2× 4-wide RAIDZ2 over a single 8-wide RAIDZ2

- **Faster resilvers** — rebuilding within a 4-drive vdev is significantly faster
  than across an 8-drive vdev
- **Better I/O parallelism** — ZFS stripes across vdevs, so 2 vdevs = 2× the IOPS
  of a single vdev
- **Safer operationally** — a single 8-wide vdev puts all eggs in one basket
- **Tradeoff** — slightly less space-efficient (50% overhead vs 25%), but the
  safety and performance gains are worth it at this drive size

### Why not mirrors (like onedr0p)

onedr0p runs 6 mirrored pairs (12× 22TB) in an HL15 with 15 bays. That works
because:
- He has bays to spare (15 vs our 8)
- His NAS serves both Ceph and NFS — IOPS matter
- 50% capacity loss is acceptable with 264TB raw

For our 8-bay HL8:
- Mirrors would give 4 pairs × 18TB = **~72TB usable** — same as 2× RAIDZ2 but
  with less redundancy per pair (1 drive tolerance vs 2)
- Our latency-sensitive workloads run on local NVMe (Rook-Ceph) — the NAS
  primarily needs throughput and capacity, not peak IOPS
- RAIDZ2 is the better fit for a bulk/backup NAS role

### Dataset Layout (Permanent)

Same structure as Phase 1, with additional datasets for long-term use.

```
tank/
├── backups/
│   ├── ceph/           # Rook-Ceph backups (etcd, Velero, RBD exports)
│   └── clients/        # Laptop/device backups
├── media/              # Plex, *arr apps
├── homelab/
│   ├── k8s-exports/    # NFS PVCs for the Talos cluster
│   └── vm-images/      # VM disk images (if ever needed)
└── scratch/            # temp workspace
```

| Dataset | compression | recordsize | atime | sync | Notes |
|---------|-------------|------------|-------|------|-------|
| `tank/backups/ceph` | zstd-3 | 1M | off | standard | Large sequential backup writes |
| `tank/backups/clients` | zstd-5 | 1M | off | standard | Higher compression, backup data compresses well |
| `tank/media` | lz4 | 1M | off | standard | Already-compressed video/audio |
| `tank/homelab/k8s-exports` | zstd-3 | 128K | off | standard | Mixed k8s PVC I/O (Prometheus, databases, apps) |
| `tank/homelab/vm-images` | zstd-3 | 64K | off | standard | Random I/O, small block writes |
| `tank/scratch` | lz4 | 128K | off | disabled | Expendable temp data |

### ZFS Snapshot Policy

| Dataset | Hourly | Daily | Weekly | Monthly |
|---------|--------|-------|--------|---------|
| `tank/backups/ceph` | 24 | 14 | — | 3 |
| `tank/backups/clients` | — | 7 | 4 | 6 |
| `tank/media` | — | 7 | 4 | — |
| `tank/homelab/k8s-exports` | 24 | 14 | 4 | 3 |
| `tank/scratch` | — | — | — | — |

### Automation

Pool creation is manual (TrueNAS UI: 2× RAIDZ2 vdevs, 4 disks each). Then:

```bash
# Update phase in host vars
# ansible/inventory/host_vars/hl8/vars.yml → truenas_phase: phase2

task ansible:configure
```

This creates all common + Phase 2 datasets, sets ZFS properties, and
configures NFS exports, snapshots, SMART tests, and scrub schedules.

---

## Kubernetes NFS StorageClass

Single StorageClass pointing to the HL8 over the 10GbE SFP+ network:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-hl8
provisioner: nfs.csi.k8s.io
parameters:
  server: 192.168.5.40
  share: /mnt/tank/homelab/k8s-exports
  subDir: ${pvc.metadata.namespace}-${pvc.metadata.name}
reclaimPolicy: Delete
volumeBindingMode: Immediate
mountOptions: ["nfsvers=4.2", "nconnect=8", "hard", "noatime"]
```

Prometheus, databases, and all other k8s PVCs use this class. If specific workloads
need isolation later (e.g., databases on a dataset with smaller recordsize), create
additional StorageClasses pointing to different NFS exports.

---

## Migration: Phase 1 → Phase 2

1. Back up critical data from `tank` to external SSD (or verify rsnapshot is current)
2. Power down the HL8
3. Replace all 5× 4TB drives with 8× 18TB drives
4. Boot TrueNAS, create new pool in UI: `tank`, 2× RAIDZ2 vdevs (4 disks each)
5. Network auto-detection should pick up the SFP+ at 192.168.5.40/24
6. Update `ansible/inventory/host_vars/hl8/vars.yml`:
   ```yaml
   truenas_phase: phase2
   ```
7. Re-run Ansible:
   ```bash
   task ansible:configure
   ```
8. Restore data from external SSD / re-sync from cluster
9. Verify Talos nodes reconnect to NFS

The dataset paths (`/mnt/tank/homelab/k8s-exports`, etc.) remain identical between
phases — the Kubernetes StorageClass doesn't need to change.

---

## UPS / NUT Server

The HL8 runs as a **NUT master** for the CyberPower CP1500PFCLCD (USB HID).
Ansible configures the UPS service and enables remote monitoring on port **3493**
so the Talos k8s nodes can act as NUT clients.

| Setting | Value |
|---------|-------|
| Mode | MASTER |
| Driver | `usbhid-ups$CP1500EPFCLCD` |
| Port | auto (USB) |
| Monitor user | `upsmon` (password in SOPS) |
| Remote monitor | Enabled (port 3493) |
| Shutdown trigger | LOWBATT |
| Power down after shutdown | Yes |
| Host sync interval | 15s |
| Shutdown timer | 30s |
| No-comm warning | 300s |

> **Driver format note:** TrueNAS requires the full `driver$model` string from
> `midclt call ups.driver_choices`, not just the driver name. The CP1500PFCLCD
> maps to the `CP1500EPFCLCD` entry (PFC/EPFC variants use the same driver).

### Talos NUT client

Talos nodes use the `siderolabs/nut-client` system extension to monitor battery
status via the HL8 NUT server. On low battery:

1. UPS switches to battery → NUT server (TrueNAS) detects it
2. NUT clients (Talos nodes) receive low-battery signal
3. Talos nodes drain workloads and shut down
4. TrueNAS syncs ZFS + shuts down
5. UPS powers off

## Prometheus Monitoring

The `prometheus` user is a read-only service account in the
`truenas_readonly_administrators` group. A Kubernetes-deployed exporter
(`truenas-scale-api-prometheus-exporter`) scrapes the TrueNAS API using an
API key bound to this user.

| Component | Location |
|-----------|----------|
| Exporter deployment | `kubernetes/apps/o11y/truenas-exporter/` |
| API key secret | `kubernetes/apps/o11y/truenas-exporter/app/secret.sops.yaml` (SOPS-encrypted) |
| User config | `ansible/inventory/host_vars/hl8/vars.yml` → `truenas_users[prometheus]` |
