# Runbook: iSCSI Volume Read-Only Recovery

## Alert

**ISCSIVolumeReadOnly** — an ext4 filesystem on a Democratic-CSI iSCSI volume has device errors, indicating the filesystem was remounted read-only (`emergency_ro`) or encountered I/O failures.

## When this fires

The Linux kernel detected I/O errors or an aborted ext4 journal on an iSCSI-backed PVC. The `node_filesystem_device_error` metric reports `1` for affected volumes. Common triggers:

- TrueNAS NAS briefly went offline or rebooted
- Network blip between a Talos node and `nas.securimancy.com:3260`
- iSCSI initiator timeout / session drop

This typically affects **all iSCSI volumes on the affected node(s)**, not just one. Check whether multiple nodes are impacted before starting recovery.

## Assess the damage

### 1. Identify affected volumes via Prometheus

```bash
# Query Prometheus for volumes with device errors
kubectl port-forward -n o11y svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=node_filesystem_device_error{mountpoint=~"/var/lib/kubelet/plugins/kubernetes.io/csi/org.democratic-csi.*",fstype="ext4"} == 1' \
  | python3 -c "import sys,json; [print(f'{r[\"metric\"][\"instance\"]} {r[\"metric\"][\"device\"]}') for r in json.load(sys.stdin)['data']['result']]"
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

## Recovery: Delete affected pods

With `checkFilesystem` enabled in democratic-csi, deleting a pod triggers the following chain:

1. Pod deleted → volume unmounted from pod
2. If no other pods use the volume → CSI NodeUnstageVolume disconnects the iSCSI session
3. New pod scheduled → CSI NodeStageVolume reconnects iSCSI and runs `e2fsck -p` before mounting
4. `e2fsck` clears the ext4 error flag in the superblock → `device_error` returns to `0`

### Delete all pods on iSCSI volumes

```bash
kubectl get pods --all-namespaces -o json | python3 -c "
import sys, json
data = json.load(sys.stdin)
for pod in data['items']:
    ns = pod['metadata']['namespace']
    name = pod['metadata']['name']
    phase = pod.get('status',{}).get('phase','')
    for v in pod.get('spec',{}).get('volumes',[]):
        if v.get('persistentVolumeClaim',{}).get('claimName',''):
            if phase == 'Running':
                print(f'{ns} {name}')
                break
" | while read ns name; do
  echo "Deleting $ns/$name"
  kubectl delete pod -n "$ns" "$name" --grace-period=30
done
```

### If pod deletion alone doesn't clear errors

If `device_error` persists after pod restart (the ext4 superblock error flag can survive unmount/remount without `e2fsck`), fall back to a node reboot:

```bash
NODE=<node-name>
kubectl cordon $NODE
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --timeout=120s
talosctl -n $NODE reboot
# Wait for Ready
kubectl get node $NODE -w
kubectl uncordon $NODE
```

Repeat for each affected node, starting with the node that has the fewest affected mounts.

### If VolSync source backups keep failing

An interrupted iSCSI session can corrupt a VolSync mover's temporary source PVC
or Kopia cache PVC. Typical symptoms include `read-only file system`,
`input/output error`, `Cache corruption detected`, or
`own-writes directory contains ... uncommitted files` in the `volsync-src-*`
pod logs.

Reset only the affected VolSync source state and trigger a fresh backup:

```bash
task volsync:reset-source NS=<namespace> APP=<app>
```

This runs `ansible/playbooks/volsync-reset-source.yml`. The playbook deletes
the `volsync-src-<app>` Job, `volsync-<app>-src` temporary PVC and
VolumeSnapshot, and `volsync-src-<app>-cache` Kopia cache PVC while the
VolSync controller is temporarily scaled to zero so it cannot immediately
recreate the Job. It restores the controller afterward and does not touch the
live application PVC.

## Verify recovery

```bash
# Check device errors cleared
kubectl port-forward -n o11y svc/kube-prometheus-stack-prometheus 9090:9090 &
curl -s 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=node_filesystem_device_error{mountpoint=~"/var/lib/kubelet/plugins/kubernetes.io/csi/org.democratic-csi.*",fstype="ext4"} == 1' \
  | python3 -c "import sys,json; r=json.load(sys.stdin)['data']['result']; print(f'Volumes with errors: {len(r)}')"

# No crashing pods
kubectl get pods -A | grep -v Running | grep -v Completed

# All nodes ready
kubectl get nodes
```

## Root cause investigation

After recovery, check TrueNAS for the underlying cause:

- **TrueNAS alerts**: check the web UI at `192.168.5.40` for any disk/pool/network alerts
- **iSCSI target status**: Sharing → Block Shares (iSCSI) — verify all targets/extents are online
- **Pool health**: Storage → Pools — check for degraded pools or disk errors
- **Network**: check switch logs / UPS status for any outage around the time of the alert
- **Cloud Sync / rclone**: check if an OOM event from rclone caused a reboot (see `journalctl -k --grep oom`)
