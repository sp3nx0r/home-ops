# Runbook: iSCSI Volume Read-Only Recovery

## Alert

**ISCSIVolumeReadOnly** — an ext4 filesystem on a Democratic-CSI iSCSI volume has been remounted read-only (`emergency_ro`).

## When this fires

The Linux kernel detected I/O errors or an aborted ext4 journal on an iSCSI-backed PVC and remounted the filesystem read-only to prevent data corruption. Common triggers:

- TrueNAS NAS briefly went offline or rebooted
- Network blip between a Talos node and `nas.securimancy.com:3260`
- iSCSI initiator timeout / session drop

This typically affects **all iSCSI volumes on the affected node(s)**, not just one. Check whether multiple nodes are impacted before starting recovery.

## Assess the damage

### 1. Identify affected nodes

```bash
for n in miirym palarandusk aurinax; do
  count=$(talosctl -n $n read /proc/mounts 2>/dev/null | grep -c emergency_ro)
  echo "$n: $count emergency_ro mounts"
done
```

### 2. Check which pods are crashing

```bash
kubectl get pods -A | grep -v Running | grep -v Completed
```

Pods on read-only volumes will typically show `CrashLoopBackOff` or `Error`.

### 3. Confirm iSCSI has reconnected

```bash
# Check kernel logs for recent iSCSI errors vs recovery
talosctl -n <node> dmesg | grep -i "iscsi\|connection.*error\|session.*recovery"
```

If iSCSI sessions are **still down**, fix the network/NAS issue first. The recovery below only works once iSCSI is healthy again.

## Recovery: Rolling node reboot

The only way to clear `emergency_ro` is to unmount and remount the filesystem. On Talos Linux, the cleanest path is a node reboot. Do this one node at a time to maintain cluster availability.

### For each affected node

```bash
NODE=<node-name>

# 1. Cordon — prevent new pods from scheduling
kubectl cordon $NODE

# 2. Drain — evict all workloads
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=120s

# If a pod gets stuck terminating:
# kubectl delete pod -n <namespace> <pod> --force --grace-period=0

# 3. Reboot
talosctl -n $NODE reboot

# 4. Wait for the node to come back (typically 1-2 minutes)
kubectl get node $NODE -w
# Wait until STATUS = Ready,SchedulingDisabled

# 5. Verify no emergency_ro mounts remain
talosctl -n $NODE read /proc/mounts | grep emergency_ro
# Expected: no output

# 6. Uncordon — allow scheduling again
kubectl uncordon $NODE
```

Repeat for each affected node. Order recommendation: start with the node that has the fewest affected mounts.

### After all nodes are rebooted

StatefulSets that were scaled down for the fix need to be scaled back up:

```bash
# Check for any StatefulSets at 0 replicas that shouldn't be
kubectl get statefulsets -A -o wide
```

Pods that were in `CrashLoopBackOff` due to read-only mounts will self-heal once the node is rebooted and the volume is remounted read-write. You may need to delete pods stuck in backoff to speed up recovery:

```bash
kubectl delete pod -n <namespace> <pod-name>
```

## Verify recovery

```bash
# All nodes ready
kubectl get nodes

# No emergency_ro mounts on any node
for n in miirym palarandusk aurinax; do
  count=$(talosctl -n $n read /proc/mounts 2>/dev/null | grep -c emergency_ro)
  echo "$n: $count emergency_ro mounts"
done

# No crashing pods
kubectl get pods -A | grep -v Running | grep -v Completed
```

## Root cause investigation

After recovery, check TrueNAS for the underlying cause:

- **TrueNAS alerts**: check the web UI at `192.168.5.40` for any disk/pool/network alerts
- **iSCSI target status**: Sharing → Block Shares (iSCSI) — verify all targets/extents are online
- **Pool health**: Storage → Pools — check for degraded pools or disk errors
- **Network**: check switch logs / UPS status for any outage around the time of the alert
