---
name: iscsi-storage-latency-triage
description: Diagnoses slow iSCSI-backed (democratic-csi, TrueNAS zvol) workloads in home-ops by mapping PVC → node device → zvol, comparing per-device write/flush latency, checking the ZFS pool read-only, and ranking noisy neighbours. Use when an app on an iscsi PVC is slow, its readiness flaps under load, SQLite/DB "slow statement" warnings appear, or someone suspects the NAS. For read-only remounts and I/O errors use docs/runbooks/runbook-iscsi-readonly.md instead.
---

# iSCSI storage latency triage

## Mission

Decide whether a slow app is a victim of pool-wide sync-write latency, a noisy neighbour, or its own I/O pattern, backed by per-device numbers. Change nothing on the NAS or the cluster.

## Prerequisites

- `source scripts/o11y.sh` from inside the repo (`q`, `qr`, `tq`, `tqr`). node-exporter instances are `192.168.5.5{0,1,2}:9100`.
- `talosctl -n <ip>`; nodes miirym `.50`, palarandusk `.51`, aurinax `.52`.
- NAS: `ssh -o BatchMode=yes truenas_admin@192.168.5.40` has passwordless `sudo -n` for read-only `zpool`/`zfs`/`iostat`/`smartctl`. The login shell is zsh, so pipe a `bash -s` heredoc. **Never change ZFS properties without explicit approval.**
- zvols live under `tank/homelab/k8s-iscsi`. Context: `docs/completed/sata-ssd-special-vdev-plan.md`, `docs/nas-storage-plan.md`. Symptom-level forensics: `o11y-history-forensics`.

## Workflow

1. **PVC → node → PV**:
    ```sh
    PV=$(kubectl -n <ns> get pvc <claim> -o jsonpath='{.spec.volumeName}')
    kubectl get volumeattachment -o json | jq -r --arg pv $PV '.items[]|select(.spec.source.persistentVolumeName==$pv)|.spec.nodeName'
    ```
2. **PV → block device on the node** (Talos has no shell; symlink targets suffice):
    ```sh
    talosctl -n <ip> ls -l /dev/disk/by-path | rg iscsi | sed -E 's/.*csi-(pvc-[0-9a-f-]+)-lun-0 -> .*\/(sd[a-z]+)$/\2 \1/'
    ```
    Resolve each `pvc-…` with `kubectl get pv <pvc> -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}'`.
3. **Per-device latency and flush rate** on that node:
    ```sh
    I='instance="192.168.5.51:9100",device=~"sd.+"'
    q "1000*rate(node_disk_write_time_seconds_total{$I}[6h]) / clamp_min(rate(node_disk_writes_completed_total{$I}[6h]),1e-9)"
    q "rate(node_disk_flush_requests_total{$I}[6h])"
    q "1000*rate(node_disk_flush_requests_time_seconds_total{$I}[6h]) / clamp_min(rate(node_disk_flush_requests_total{$I}[6h]),1e-9)"
    ```
    Similar latency on every volume means the pool, not this volume. Then compare the victim's **flush rate**: a high-fsync app feels pool latency far more than one at 0.01–0.3 flushes/s.
4. **Node-specific or cluster-wide, and since when**: the same ratios with `sum by (instance)` over `device=~"sd.+"`, local `nvme.n.` as a baseline, and `tqr` over days (`tqr '<expr>' 168 10800`) to find the step change.
5. **NAS side (read-only)**:
    ```sh
    ssh -o BatchMode=yes truenas_admin@192.168.5.40 'bash -s' <<'EOF'
    sudo -n zpool list -v tank
    sudo -n zfs get -H -o property,value logbias,sync tank/homelab/k8s-iscsi
    sudo -n zfs get -H -r -t volume -o property,value volblocksize,sync,special_small_blocks tank/homelab/k8s-iscsi | sort | uniq -c   # per-zvol; outliers stand out
    sudo -n zpool iostat -vl tank 10 2
    iostat -dx 10 2 | awk '/Device/{h++} h==2'
    EOF
    ```
    Look for: no `logs` vdev (SLOG), zvols that differ from the rest (all 52 were `16K`/`standard` at last check), slower HDD members (`smartctl -i` rotation rate).
6. **Noisy neighbour**: map `zdN` → zvol on the NAS (`for z in /dev/zvol/tank/homelab/k8s-iscsi/*; do echo "$(basename $(readlink -f $z)) $(basename $z)"; done`), join with `iostat -dx` for `zd*`, and resolve the top zvol to its PVC. Match its client-side rate (steps 2–3 on its node) against the latency timeline and `git log` for the commit that triggered it.
7. **Rule things out with numbers**: NIC speed/MTU/errors (`talosctl -n <ip> read /sys/class/net/<if>/speed`), ping RTT, scrub state, vdev errors, ARC hit ratio. `truenas_*` metrics cover pool health but only aggregate disk busy.
8. **Confirm cause and effect** before proposing hardware or ZFS changes: throttle or scale the suspect (with permission), then compare 15-minute windows at fixed `time=` points.

## Gotchas & Edge Cases

- **A node-wide maximum misattributes latency.** The first pass blamed brrpolice; per-device numbers showed it had the _best_ latency on the node and was simply the most fsync-sensitive.
- **The busiest zvol isn't necessarily the victim's problem.** The busiest `zdN` was kubescape-storage. Resolve every `zdN` before concluding.
- NAS-side wait (~4 ms) vs client-side (~40 ms) with a clean network meant ZIL commits waiting on HDDs. Prove the network clean; don't assume it.
- TrueNAS's 15-minute busy average is skewed by rollout bursts and top-of-hour Volsync runs. Take a live `iostat` sample before calling a fix ineffective.
- `special_small_blocks` reports `-` on these zvols, so sending small zvol blocks to the special vdev is unverified here. Recommend testing on one zvol and watching the special vdev `ALLOC` before claiming it helps.
- `volblocksize` exists only on zvols; querying it on the parent dataset returns `-`. Use `-r -t volume`.
- **Correlation isn't causation**: brrpolice recovered when a busy torrent left scope, before the Kubescape fix landed. Check the app's own load metrics first.
- Chart-default CPU limits can throttle components even when the HR sets only memory. Check live `.resources` before ruling throttling out.

## Output Template

```
Verdict: <pool-wide | noisy neighbour <ns/pvc> | app I/O pattern> — <one sentence of evidence>
| device | ns/claim | writes/s | flushes/s | write ms | flush ms |
Timeline: before/after <commit/date>: cluster write/flush ms
NAS: layout, SLOG?, special_small_blocks, slowest disks; network ruled out by <numbers>
Fixes (quickest first): workload-side · ZFS property (test first) · hardware
Changed: nothing (or exactly what, with approval)
```
