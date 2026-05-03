# SATA SSD Special VDEV Plan

> Hardware: 2× 500GB SATA SSDs (2.5" form factor)
> Target: 45Drives HL8 NAS (themberchaud) — TrueNAS SCALE
> Purpose: Mirrored ZFS special vdev for metadata + small block acceleration

## Status: Pending Physical Fit Check

**Blocker:** Need 2.5" to 3.5" adapter brackets for the HL8's hot-swap bays.

- **Drive height: 7mm** — WD Blue SATA SSDs (SA510, 3D NAND, all generations)
  are 7mm. Get 7mm-compatible adapters.
- 2.5" to 3.5" adapter brackets (~$5–8 each)
- Some hot-swap cages accept 2.5" drives with bottom-mount screw holes — check
  if the HL8 trays have these before buying adapters
- The HL8 motherboard may have an internal SATA header or M.2 SATA slot — if so,
  one or both SSDs could mount internally without using a bay

## What Is a Special VDEV

A ZFS special vdev is a dedicated device (or mirror) that stores:

1. **Pool metadata** — block pointers, indirect blocks, dedup tables
2. **Small file blocks** — files below a configurable size threshold
   (`special_small_blocks` dataset property, e.g. 64K)

All other data (large files, media, backups) stays on the main RAIDZ vdevs.

### Why This Matters

Spinning disks are slow at random I/O. ZFS metadata operations (scrubs, directory
listings, snapshot diffs, `stat` calls) scatter reads across the entire pool. Moving
that metadata onto SSDs means:

| Operation | Without special vdev | With special vdev |
|-----------|---------------------|-------------------|
| `zfs scrub` | Hours (seeks across all 5 disks) | Significantly faster (metadata on SSD) |
| NFS `readdir` / `stat` | Disk-bound random reads | SSD-speed |
| iSCSI zvol metadata | Random seeks on RAIDZ | SSD-speed |
| Small file reads (<64K) | Disk-bound | SSD-speed |
| Large file streaming | Disk-speed | Unchanged (still on RAIDZ) |

This is the single highest-impact ZFS acceleration for a NAS that serves NFS PVCs
and iSCSI zvols to a Kubernetes cluster.

## Why Mirror Is Mandatory

A special vdev stores irreplaceable pool metadata. If an unmirrored special vdev
dies, **the entire pool is lost** — not just the data on the SSD. Two 500GB SSDs
as a mirror provide single-drive fault tolerance for the special vdev, matching
the RAIDZ1 tolerance of the main pool.

## Bay Budget

### Phase 1 (current): 5× 4TB RAIDZ1

| Bays | Contents |
|------|----------|
| 1–5 | 4TB HDDs (RAIDZ1) |
| 6–7 | **500GB SSDs (special mirror)** |
| 8 | Empty |

3 bays were free, using 2 for SSDs leaves 1 spare. No conflict.

### Phase 2 (planned): 8× 18TB drives

The original plan uses all 8 bays for HDDs (2× 4-drive RAIDZ2). Adding the SSDs
requires one of these adjustments:

| Option | Layout | Usable | Trade-off |
|--------|--------|--------|-----------|
| **A: Keep special vdev, 6 data drives** | 1× 6-wide RAIDZ2 + 2× SSD mirror | ~72TB | Same usable space, fewer IOPS (1 vdev vs 2), but metadata on SSD compensates |
| **B: Keep special vdev, 6 data drives (mirrors)** | 3× 2-drive mirrors + 2× SSD mirror | ~54TB | Best random IOPS, worst capacity |
| **C: Remove special vdev at Phase 2** | 2× 4-drive RAIDZ2 (original plan) | ~72TB | Remove SSDs before rebuilding pool; metadata redistributes to HDDs (supported since OpenZFS 2.2+) |
| **D: Mount SSDs internally** | 2× 4-drive RAIDZ2 + internal SSD mirror | ~72TB | Best of both worlds — requires internal SATA headers or M.2 SATA on the HL8 board |

**Option C** is the safest default — get the special vdev benefit now during Phase 1,
remove it when Phase 2 drives arrive, and reconsider if internal mounting is viable.

**Option D** is ideal if the HL8 board has spare SATA ports and physical space for
2.5" drives inside the chassis.

## Setup (TrueNAS SCALE)

### 1. Add the special vdev to the existing pool

In TrueNAS UI: Storage → Pool → `tank` → Add VDEV → select both SSDs → type:
**Special (Metadata)** → mirror.

Or via CLI:

```bash
# Identify the SSD device names
lsblk

# Add mirrored special vdev to tank
zpool add tank special mirror /dev/sdX /dev/sdY
```

### 2. Configure small block threshold (optional)

By default, only metadata lands on the special vdev. To also accelerate small
files, set `special_small_blocks` on datasets with mixed I/O:

```bash
# k8s PVCs — lots of small files (configs, databases, app state)
zfs set special_small_blocks=64K tank/homelab/k8s-exports
zfs set special_small_blocks=64K tank/homelab/k8s-iscsi

# Backups — large sequential writes, no benefit from small block offload
# (leave default: 0)

# Media — large files, no benefit
# (leave default: 0)
```

Only **new writes** after setting this property land on the special vdev. Existing
data stays on the RAIDZ vdev unless rewritten.

### 3. Verify

```bash
zpool status tank
# Should show:
#   special
#     mirror-1
#       sdX  ONLINE
#       sdY  ONLINE

zpool list -v tank
# Special vdev should show allocated metadata + small blocks
```

## Monitoring

Watch special vdev utilization — if it fills up, ZFS falls back to writing metadata
on the main vdevs (graceful degradation, not a failure). With 500GB mirrored and a
16–72TB pool, this is unlikely to be an issue.

```bash
zpool list -v tank
```

The special vdev `ALLOC` column shows usage. Metadata is typically 1–3% of pool
size. With `special_small_blocks=64K` on active datasets, usage will be higher but
500GB provides substantial headroom.

## Alternatives Considered

### SLOG (ZIL device)

A mirrored SLOG accelerates synchronous write latency. Rejected because:
- 500GB is ~50× oversized for SLOG (only holds ~10s of in-flight writes)
- Benefit is narrow — only sync writes, not reads or metadata
- Most datasets use `sync=standard` and the NFS mount options don't force sync
- Special vdev provides broader acceleration

### L2ARC (read cache)

SSD as a read cache tier when ARC (RAM) is full. Rejected because:
- L2ARC uses RAM to index its contents (~70 bytes per cached block), reducing
  effective ARC size on a 32GB system
- Workloads are primarily sequential (media streaming, backups) — L2ARC helps
  random reads
- Special vdev captures the random-read-heavy metadata workload more efficiently

### Talos nodes / sardior

No practical use — Talos nodes use NVMe M.2 slots (not 2.5" SATA), and sardior
(MS-S1) already has 2TB NVMe with 128GB RAM.
