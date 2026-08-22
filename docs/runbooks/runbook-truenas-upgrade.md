# Runbook: TrueNAS Upgrade (HL8 / themberchaud)

Planned maintenance procedure for upgrading TrueNAS SCALE on the HL8 NAS
(`192.168.5.40`) without corrupting iSCSI-backed Kubernetes PVCs.

## Background

TrueNAS reboots during upgrade take down both NFS exports and iSCSI targets.
The cluster reacts differently to each:

| Storage path | Apps | During outage | After recovery |
|--------------|------|---------------|----------------|
| **iSCSI** (`storageClass: iscsi`) | ~51 PVCs — Prometheus, Grafana, Garage, Pocket ID, Loki, etc. | Pods get I/O errors; ext4 may remount **read-only** (`emergency_ro`) | Requires clean unmount + `e2fsck` via democratic-csi `checkFilesystem` |
| **NFS** (`192.168.5.40`) | Media stack, Kopia repo, app configs | Hard mounts **hang** (block I/O) until NAS returns | Usually self-heals; no filesystem repair needed |
| **Encrypted datasets** | All of the above | Locked until passphrase entered | Run `task ansible:nas:unlock` |

**Do not cordon or drain Talos nodes.** The iSCSI initiator on each node retries
sessions automatically. Only scale down **workloads** that hold iSCSI PVCs.

### Lessons from prior maintenance

| Date | Event | Outcome |
|------|-------|---------|
| May 2026 | CVE patch to 25.10.3.1 (reboot, no preemptive drain) | Cluster self-healed after `task ansible:nas:unlock`; brief alert storm |
| May 2026 | NAS reboot without preemptive drain | iSCSI ext4 volumes went read-only; mass pod restart + `e2fsck` recovery needed; led to `task ansible:iscsi:restart` |
| Aug 2026 | Planned upgrade with preemptive drain | `task ansible:iscsi:restore` brought 27 workloads back; a few pods failed on first mount timing — pod restart was enough; **Volsync restore was not needed** |

**Recommendation:** Always **preemptively drain** iSCSI workloads before a
TrueNAS reboot. This cleanly unstages volumes before targets disappear and
avoids read-only filesystem corruption.

**Do not run Volsync/Kopia restore** as part of a normal TrueNAS upgrade.
Volsync is paused during drain and resumes automatically when `task ansible:iscsi:restore`
completes. Backup restore is only for actual data loss or corruption that survives
a pod restart (see [runbook-restore-pvc.md](../backup-and-recovery/runbook-restore-pvc.md)).

## Prerequisites

- Cluster access: `KUBECONFIG=/opt/home-ops/kubeconfig`
- Ansible venv initialized: `task ansible:init`
- TrueNAS SSH access: `ssh truenas_admin@192.168.5.40`
- Encryption passphrase available (4 datasets: `tank/backups`, `tank/homelab`, `tank/media`, `tank/scratch`)
- Maintenance window (~30–60 min for patch upgrades; longer for major versions)
- Optional: silence Alertmanager maintenance alerts for `ISCSIVolumeReadOnly`, Volsync, and endpoint failures

## Pre-flight checks

```bash
# NAS version and pool health
ssh truenas_admin@192.168.5.40 'midclt call system.info | jq "{version, hostname, uptime}"'
ssh truenas_admin@192.168.5.40 'zpool status tank'

# Cluster baseline
kubectl get nodes
kubectl get pods -A --field-selector='status.phase!=Running,status.phase!=Succeeded'

# Confirm democratic-csi checkFilesystem is enabled (required for e2fsck on remount)
kubectl -n kube-system get secret democratic-csi-driver-config -o jsonpath='{.data.driver\.json}' \
  | base64 -d | jq '.driverConfig.filesystems'
```

Patch upgrades within the same train (e.g. 25.10.x → 25.10.y) do **not** require
Ansible playbook changes. The `truenas-configure.yml` playbook is API-driven and
tolerates point releases.

## Procedure

### Phase 1 — Drain iSCSI workloads (pre-upgrade)

Scale down all deployments/statefulsets using iSCSI PVCs and pause Volsync.
Replica counts are saved to `~/.cache/home-ops/iscsi-maintenance-state.json`.

```bash
task ansible:iscsi:drain
```

Verify nothing is holding iSCSI volumes:

```bash
kubectl get pods -A -o json | python3 -c "
import json, sys
pods = json.load(sys.stdin)['items']
iscsi = [f\"{p['metadata']['namespace']}/{p['metadata']['name']}\"
         for p in pods if p.get('status',{}).get('phase') not in ('Succeeded','Failed')
         for v in p.get('spec',{}).get('volumes',[])
         if v.get('persistentVolumeClaim')]
# cross-check with PV storageClass in a full script; quick sanity:
print('Running pods with any PVC:', len(iscsi))
"

kubectl -n volsync-system get deploy volsync -o jsonpath='replicas={.spec.replicas}{"\n"}'
# Expected: replicas=0
```

NFS-only workloads (media stack, etc.) can stay running. They will hang on I/O
during the reboot but recover once NFS is back.

Optional: pause TrueNAS Cloud Sync tasks in the UI (Data Protection → Cloud Sync)
to avoid a failed sync run during the outage. Ansible will re-enable them on the
next `task ansible:nas` run if needed.

### Phase 2 — Upgrade TrueNAS

1. Open TrueNAS UI: `https://nas.securimancy.com` (or `https://192.168.5.40`)
2. Check **System → Update** for available version and release notes
3. Take a screenshot of the current version
4. Apply the update
5. Reboot when prompted

Wait for the NAS to come back (~5–10 min):

```bash
until ssh -o ConnectTimeout=5 truenas_admin@192.168.5.40 'echo ok' 2>/dev/null; do
  echo "Waiting for NAS..."
  sleep 15
done
```

### Phase 3 — Unlock encrypted datasets

All four encrypted top-level datasets lock on reboot.

```bash
task ansible:nas:unlock
```

This unlocks `tank/backups`, `tank/homelab`, `tank/media`, and `tank/scratch`,
then restarts NFS and iSCSI services.

Verify:

```bash
ssh truenas_admin@192.168.5.40 \
  'midclt call pool.dataset.query '"'"'[["locked", "=", true]]'"'"' | jq length'
# Expected: 0

ssh truenas_admin@192.168.5.40 'midclt call service.query | jq ".[] | select(.service==\"iscsitarget\" or .service==\"nfs\") | {service, state}"'
# Expected: state RUNNING for both
```

### Phase 4 — Restore iSCSI workloads (post-upgrade)

Bring workloads back from saved replica counts using the Ansible playbook
`ansible/playbooks/iscsi-restart-pods.yml`. democratic-csi runs `e2fsck -p`
during volume restage.

```bash
task ansible:iscsi:restore
```

This reads replica counts from `~/.cache/home-ops/iscsi-maintenance-state.json`
(written by `task ansible:iscsi:drain`), scales each deployment/statefulset back
up, restores the Volsync controller, and waits for rollouts. It does **not**
restore PVC data from Kopia — it only brings workloads back online.

| Task | When to use |
|------|-------------|
| `task ansible:iscsi:drain` | Pre-upgrade — scale down iSCSI workloads, save state |
| `task ansible:iscsi:restore` | Post-upgrade — scale workloads back up from saved state |
| `task ansible:iscsi:restart` | Skipped drain, or unplanned outage — drain + restore in one pass |

If `iscsi:restore` hangs on rollout timeouts, check failing pods individually
(see troubleshooting below) rather than reaching for Volsync restore.

### Phase 5 — Verify cluster health

```bash
# All pods running
kubectl get pods -A --field-selector='status.phase!=Running,status.phase!=Succeeded'

# Nodes ready
kubectl get nodes

# Flux reconciled
flux get kustomizations -A | grep -v True

# Spot-check critical apps
kubectl -n o11y get pods -l app.kubernetes.io/name=kube-prometheus-stack
kubectl -n storage get pods -l app.kubernetes.io/name=garage
kubectl -n security get pods -l app.kubernetes.io/name=pocket-id

# Confirm no stale alerts (may take a few minutes to clear)
kubectl -n o11y exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  wget -qO- http://localhost:9093/api/v2/alerts 2>/dev/null \
  | python3 -c "import sys,json; print(len(json.load(sys.stdin)), 'active alerts')"
```

### Troubleshooting after restore

Most post-upgrade issues are **startup timing**, not data loss. After unlock,
confirm iSCSI is healthy before running `iscsi:restore`:

```bash
ssh truenas_admin@192.168.5.40 \
  'midclt call service.query | jq ".[] | select(.service==\"iscsitarget\") | .state"'
# Expected: RUNNING
```

If individual pods fail on first boot (e.g. app errors while iSCSI mounts were
still settling, or a dependency like Garage wasn't ready yet):

```bash
# Restart a single stuck pod
kubectl delete pod -n <namespace> <pod-name>

# Or re-run the full bring-up (safe if state file still exists)
task ansible:iscsi:restore
```

Apps that depend on other services (Loki/Pocket ID → Garage S3) may need a pod
delete after their dependency is healthy — not a Volsync restore.

For ext4 read-only mounts or persistent I/O errors, see
[runbook-iscsi-readonly.md](runbook-iscsi-readonly.md). For confirmed PVC data
corruption, see [runbook-restore-pvc.md](../backup-and-recovery/runbook-restore-pvc.md).

### Phase 6 — Post-upgrade housekeeping

```bash
# Confirm NAS version
ssh truenas_admin@192.168.5.40 'midclt call system.info | jq .version'

# Reconcile Ansible config if the upgrade changed defaults you manage
task ansible:nas:dry-run

# Force Flux pull if anything drifted during maintenance
task reconcile
```

## Quick reference (TL;DR)

```bash
# 1. Drain
task ansible:iscsi:drain

# 2. Upgrade + reboot in TrueNAS UI

# 3. Unlock
task ansible:nas:unlock

# 4. Restore
task ansible:iscsi:restore

# 5. Verify
kubectl get pods -A | grep -vE 'Running|Completed'
```

## Alternative: post-hoc recovery (not recommended)

For a very short reboot where you accept possible ext4 read-only mounts, you
can skip the preemptive drain and run the all-in-one recovery after unlock:

```bash
task ansible:nas:unlock
task ansible:iscsi:restart
```

This scales down, restages with `e2fsck`, and scales back up in one pass. It
works but is more disruptive than a clean preemptive drain and may leave SQLite
apps (Pocket ID, brrpolice) in a bad state if writes were in-flight.

## Expected alert noise

During maintenance, expect firing alerts for:

- Volsync backup failures (controller scaled to 0 / NFS unavailable)
- Garage / Prometheus / Grafana endpoint failures (iSCSI apps down)
- `ISCSIVolumeReadOnly` (if preemptive drain was skipped)
- NFS-dependent health checks (media stack)

These should clear after Phase 4 completes.

## Rollback

TrueNAS SCALE does not support in-place downgrade. If an upgrade fails:

1. Do **not** panic-reboot repeatedly
2. Check TrueNAS boot environment: System → Boot → Boot Pool → Previous entry
3. If the pool is intact, boot the previous environment from the UI
4. Run Phase 3–5 above after the NAS is stable

For confirmed data corruption on a specific iSCSI PVC (after pod restart and
`e2fsck` recovery have failed), see
[runbook-restore-pvc.md](../backup-and-recovery/runbook-restore-pvc.md).
This is a separate procedure from TrueNAS upgrades.

## Related docs

- [runbook-iscsi-readonly.md](runbook-iscsi-readonly.md) — ext4 read-only recovery
- [backup-strategy.md](../backup-and-recovery/backup-strategy.md) — backup layers
- [ansible/README.md](../../ansible/README.md) — NAS Ansible playbooks
