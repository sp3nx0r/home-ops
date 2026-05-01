# Runbook: Full NAS disaster recovery

## When to use

- Total NAS hardware failure (controller, motherboard, PSU)
- Multiple simultaneous disk failures exceeding RAIDZ1 tolerance
- Physical loss (fire, theft, flood)
- Pool corruption beyond repair

## Prerequisites

- Replacement hardware with TrueNAS SCALE installed
- Internet access for B2 download
- This git repo cloned locally
- Age key (`age.key`) available for SOPS decryption

## Recovery order

Restore in priority order — critical infrastructure first, media last.

| Priority | Dataset | Size estimate | Purpose |
|----------|---------|---------------|---------|
| 1 | `homelab/k8s-exports` | Small | Kubernetes NFS PVCs |
| 2 | `homelab/kopia` | Small-medium | Volsync backup repo (needed to restore iSCSI PVC data) |
| 3 | `homelab/k8s-iscsi` | Small | iSCSI zvols (may not restore cleanly from B2 — use Kopia instead) |
| 4 | `backups` | Medium | General backups |
| 5 | `media` | Large | Media library (lowest priority, largest download) |

## Procedure

### Phase 0: Restore TrueNAS configuration (optional, if config backup available)

If you have a copy of the TrueNAS config database (from `tank/backups/truenas-config/` or B2):

1. Install TrueNAS SCALE on replacement hardware
2. During initial setup, upload the `freenas-v1-YYYYMMDD.db` and `pwenc_secret` files via System → General → Manage Configuration → Upload Config
3. Reboot — this restores all users, shares, services, datasets, cron jobs, cloud sync tasks, etc.
4. Skip to Phase 2

### Phase 1: Rebuild TrueNAS (from scratch)

1. Install TrueNAS SCALE on replacement hardware
2. Create pool `tank` in the TrueNAS UI
3. Enable SSH, create `truenas_admin` user with your SSH key + passwordless sudo
4. Run Ansible to rebuild all configuration:

```bash
task ansible:init
task ansible:configure
```

This recreates all datasets, NFS shares, snapshot tasks, users, services, iSCSI config, cloud sync tasks, and the config backup cron.

### Phase 2: Restore data from B2

**Option A: TrueNAS Cloud Sync PULL (recommended)**

1. In TrueNAS UI: Data Protection → Cloud Sync Tasks → Add
2. Direction: **PULL**
3. Credential: Add B2 credentials
4. Bucket: `sp3nx0r-truenas`
5. Remote path: `/` (or specific dataset path for priority restore)
6. Local path: `/mnt/tank`
7. Transfer mode: **COPY**
8. Run manually for each priority dataset

**Option B: rclone from CLI**

```bash
# Get B2 credentials from SOPS (run from repo root on your workstation)
eval $(sops -d ansible/inventory/group_vars/backblaze/secrets.sops.yml \
  | yq -r '"export B2_ACCOUNT=\(.b2_access_key_id)\nexport B2_KEY=\(.b2_secret_access_key)"')

# Configure rclone remote on the NAS
ssh nas
rclone config
# Add remote: name=b2, type=b2, account=$B2_ACCOUNT, key=$B2_KEY

# Restore priority datasets first
rclone sync b2:sp3nx0r-truenas/homelab/k8s-exports /mnt/tank/homelab/k8s-exports --progress
rclone sync b2:sp3nx0r-truenas/homelab/kopia /mnt/tank/homelab/kopia --progress

# Then the rest
rclone sync b2:sp3nx0r-truenas/backups /mnt/tank/backups --progress
rclone sync b2:sp3nx0r-truenas/media /mnt/tank/media --progress
```

### Phase 3: Fix ownership

```bash
ssh nas 'sudo chown -R 1000:1000 /mnt/tank/homelab/kopia'
# Other datasets may need ownership fixes depending on your user setup
```

### Phase 4: Rebuild Kubernetes cluster

```bash
# Bootstrap Talos nodes
task talos:bootstrap

# Flux will reconcile from git and redeploy all apps
# Volsync ReplicationDestinations will restore iSCSI PVC data from the Kopia repo
```

### Phase 5: Verify

- [ ] All Flux kustomizations healthy: `flux get ks -A`
- [ ] All pods running: `kubectl get pods -A`
- [ ] Volsync ReplicationDestinations completed
- [ ] NFS PVCs accessible
- [ ] Re-enable Cloud Sync PUSH task to resume offsite backups

## Estimated recovery time

| Component | Estimate | Notes |
|-----------|----------|-------|
| TrueNAS install + Ansible | 1-2 hours | Hardware-dependent |
| B2 download (k8s-exports + kopia) | Hours | Bandwidth-dependent |
| B2 download (media) | Days | Could be 1TB+, deprioritize |
| Kubernetes bootstrap | 30 minutes | Automated via Talos + Flux |
| PVC restores via Volsync | Minutes per PVC | Runs automatically after Flux reconciles |

## Important notes

- **iSCSI zvols are block devices** — they won't restore cleanly from B2 file sync. Use Volsync/Kopia to restore iSCSI PVC data instead.
- **B2 egress is metered** — first 1 GB/day free, then $0.01/GB. Budget for egress costs on large restores.
- **Don't re-enable Cloud Sync PUSH** until you've verified the restored data is correct, or you'll push incomplete data back to B2.

## TODO

- [ ] Estimate total B2 dataset size and calculate egress cost
- [ ] Test partial restore of priority datasets
- [ ] Document Talos bootstrap procedure or link to existing docs
- [ ] Create a "break glass" document with credentials stored offline
