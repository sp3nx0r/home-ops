# Runbook: Restore etcd from a snapshot

Snapshots are taken every 6 hours by `system-upgrade/etcd-backup`
(talos-backup), age-encrypted to the SOPS recipient, and uploaded to B2
`sp3nx0r-homelab-etcd`. TrueNAS mirrors them into `/mnt/tank/backups/etcd`.
Design: [etcd backup plan](../etcd-backup-plan.md).

## When to use (and when not to)

The cluster is GitOps, so **Flux can rebuild every manifest from Git** without
etcd (see [full DR, Phase 4](runbook-disaster-recovery.md#phase-4-rebuild-kubernetes-cluster)).
An etcd restore is for **speed and for state that is not in Git**:

- PV ↔ PVC bindings to the _existing_ democratic-csi zvols and NFS paths. A
  Git rebuild provisions new, empty volumes, and every app then waits for a
  Volsync restore.
- Volsync ReplicationSource/Destination status and Kopia maintenance state
- cert-manager certificates (avoids Let's Encrypt re-issuance and rate limits),
  controller-generated Secrets, webhook CAs
- Leases, events, Talos ServiceAccount Secrets, anything created by hand

Use it when **etcd quorum is lost and cannot be restored** (two or more members
dead or corrupted), or when all control-plane nodes were wiped but the NAS
survived. If the NAS was also lost, the restored PVs point at zvols that no
longer exist. In that case, prefer the Git rebuild plus Volsync restore in the
full DR runbook.

Do **not** use it for single-member failures. Replace or reset that one node
and let it rejoin.

## Prerequisites

- `age.key` (or the offline paper key), `talos/secrets.sops.yaml`, and this
  repo. **The snapshot is useless without the original secrets bundle**:
  Kubernetes Secrets in etcd are secretbox-encrypted with
  `secretboxencryptionsecret` from that bundle. Node certs must also chain to
  the same CAs.
- Tools from mise: `talosctl`, `topf`, `age`, `zstd`, `b2`, plus `docker` for
  `etcdutl`.

## Procedure

### 1. Confirm etcd really is unrecoverable

```bash
talosctl -n 192.168.5.50,192.168.5.51,192.168.5.52 etcd members
talosctl -n 192.168.5.50,192.168.5.51,192.168.5.52 service etcd
talosctl -n 192.168.5.50,192.168.5.51,192.168.5.52 get machinetype   # all must be controlplane
```

If a majority is healthy, fix quorum instead (`talosctl etcd remove-member`,
then reset and rejoin the broken node).

If a member is still up, **take a fresh snapshot first**. It is newer than
anything in B2:

```bash
talosctl -n <healthy-ip> etcd snapshot db.snapshot
# quorum already lost: copy the raw DB instead (restore later with --recover-skip-hash-check)
talosctl -n <ip> cp /var/lib/etcd/member/snap/db ./db.snapshot
```

### 2. Fetch the newest snapshot (skip if step 1 produced one)

From the NAS mirror (no egress, works offline):

```bash
ssh nas 'ls -1t /mnt/tank/backups/etcd/kubernetes/ | head -3'
scp "nas:/mnt/tank/backups/etcd/kubernetes/<object>.snap.zst.age" .
```

Or from B2 (the Ansible key in `ansible/inventory/group_vars/backblaze/secrets.sops.yml` can read it):

```bash
eval "$(sops -d ansible/inventory/group_vars/backblaze/secrets.sops.yml \
  | yq -r '"export B2_APPLICATION_KEY_ID=\(.b2_access_key_id) B2_APPLICATION_KEY=\(.b2_secret_access_key)"')"
b2 ls --long b2://sp3nx0r-homelab-etcd/kubernetes/ | sort -k3,4 | tail -3
b2 file download "b2://sp3nx0r-homelab-etcd/kubernetes/<object>.snap.zst.age" ./latest.snap.zst.age
```

### 3. Decrypt, decompress, verify

```bash
age -d -i age.key latest.snap.zst.age | zstd -d -o db.snapshot
docker run --rm -v "$PWD:/w" --entrypoint /usr/local/bin/etcdutl \
  registry.k8s.io/etcd:3.7.1 snapshot status /w/db.snapshot -w table
```

Match the etcd image tag to the cluster's
(`talosctl -n 192.168.5.50 get etcdspec -o yaml | grep image`).

### 4. Prepare the control-plane nodes

Every etcd member must end up in `Preparing` with an **empty** data dir.

- **Node is up, etcd broken:** wipe EPHEMERAL (this deletes `/var/lib/etcd`):

    ```bash
    talosctl -n <ip> reset --graceful=false --reboot --system-labels-to-wipe=EPHEMERAL
    ```

    If the node then hangs (pingable, but `talosctl` is refused), that is the
    known kexec issue on this hardware. Power-cycle it.

- **Node reinstalled or replaced:** apply config from the same secrets bundle,
  **without bootstrapping**:

    ```bash
    just talos apply        # topf apply — NOT `just bootstrap talos`
    ```

    `just bootstrap talos` runs `topf apply --auto-bootstrap`, which would
    bootstrap an **empty** etcd and defeat the restore.

Check:

```bash
talosctl -n 192.168.5.50,192.168.5.51,192.168.5.52 service etcd   # STATE Preparing on all
```

### 5. Bootstrap from the snapshot (one node only)

```bash
talosctl -n 192.168.5.50 bootstrap --recover-from=./db.snapshot
# add --recover-skip-hash-check only for a raw `talosctl cp` copy
talosctl -n 192.168.5.50 dmesg -f | grep -i -E 'recover|snapshot|etcd'
```

The other members join once the API is up:

```bash
talosctl -n 192.168.5.50 etcd members
kubectl get nodes
```

`kubeconfig`/`talosconfig` stay valid because they come from the same bundle.
If they were lost, regenerate them from `talos/`:
`topf talosconfig > clusterconfig/talosconfig` and
`topf kubeconfig --validity 8760h > ../kubeconfig`.

### 6. Reconcile the (up to 6h old) state

```bash
flux reconcile source git flux-system -n flux-system
flux reconcile ks cluster-apps -n flux-system --with-source
flux get ks -A | grep -v True
```

Then check what drifted since the snapshot:

- [ ] **PVs:** `kubectl get pv | grep -v Bound` shows PVs released or deleted
      after the snapshot. Look on TrueNAS for zvols created after the
      snapshot, which are now orphans, and reconcile them with
      `democratic-csi` before deleting anything.
- [ ] **Volsync:** `kubectl get replicationsource -A` should resume on
      schedule. ReplicationDestinations must not re-run unexpectedly.
- [ ] **Certificates:** `kubectl get certificate -A`. Certificates issued
      after the snapshot are reissued automatically.
- [ ] **Talos SAs:** `kubectl get serviceaccounts.talos.dev -A` regenerate
      their Secrets.
- [ ] **CronJobs:** runs missed inside `startingDeadlineSeconds` may fire
      immediately.
- [ ] Trigger a fresh backup:
      `kubectl -n system-upgrade create job --from=cronjob/etcd-backup etcd-backup-post-restore`.

## Drill log

| Date | Object | Type | Result |
| ---- | ------ | ---- | ------ |
|      |        |      |        |
