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

| Priority | Dataset | B2 bucket | Size estimate | Purpose |
|----------|---------|-----------|---------------|---------|
| 1 | `backups/truenas-config` | `sp3nx0r-backups-truenas-config` | Tiny | TrueNAS configuration database and secret seed |
| 2 | `homelab/k8s-exports` | `sp3nx0r-homelab` | Small | Kubernetes NFS PVCs |
| 3 | `homelab/kopia` | `sp3nx0r-homelab-kopia` | Small-medium | Volsync backup repo (needed to restore iSCSI PVC data) |
| 4 | `homelab/k8s-iscsi` | N/A | Small | iSCSI zvols (do not restore from B2 file sync; use Kopia instead) |
| 5 | `backups/workstations` + `backups/git-bundles` | `sp3nx0r-backups-workstation` | Medium | Workstation mirrors and Git bundles |
| 6 | `backups/archive` | `sp3nx0r-backups-archive` | Variable | Long-lived archive data |
| 7 | `media` | `sp3nx0r-media` | Large | Media library (lowest priority, largest download) |

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
4. Bucket: choose the bucket for the dataset being restored
5. Remote path: use the bucket-specific path from the recovery order table
6. Local path: use the matching `/mnt/tank/...` dataset path
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
# Add raw remote: name=b2-raw, type=b2, account=$B2_ACCOUNT, key=$B2_KEY
# Add crypt remotes using the TrueNAS Cloud Sync encryption password and salt:
#   b2-truenas-config -> b2-raw:sp3nx0r-backups-truenas-config
#   b2-homelab -> b2-raw:sp3nx0r-homelab
#   b2-kopia -> b2-raw:sp3nx0r-homelab-kopia
#   b2-workstations -> b2-raw:sp3nx0r-backups-workstation
#   b2-archive -> b2-raw:sp3nx0r-backups-archive
#   b2-media -> b2-raw:sp3nx0r-media

# Restore priority datasets first
rclone sync b2-truenas-config: /mnt/tank/backups/truenas-config --progress
rclone sync b2-homelab:k8s-exports /mnt/tank/homelab/k8s-exports --progress
rclone sync b2-kopia: /mnt/tank/homelab/kopia --progress

# Then the rest
rclone sync b2-workstations:workstations /mnt/tank/backups/workstations --progress
rclone sync b2-workstations:git-bundles /mnt/tank/backups/git-bundles --progress
rclone sync b2-archive: /mnt/tank/backups/archive --progress
rclone sync b2-media: /mnt/tank/media --progress
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
- [ ] Verify the Ansible-managed Cloud Sync PUSH tasks are enabled after restored data is confirmed

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
- **Suspend Cloud Sync PUSH during restore** if tasks were recreated or restored as enabled. Resume only after verifying restored data, or incomplete local data can be pushed back to B2.

## TODO

- [ ] Estimate total B2 dataset size and calculate egress cost
- [ ] Test partial restore of priority datasets
- [ ] Document Talos bootstrap procedure or link to existing docs
- [ ] Create a "break glass" document with credentials stored offline
