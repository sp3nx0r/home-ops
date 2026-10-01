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
- Age key (`age.key`) available for SOPS decryption. If the workstation is gone,
  recover it and the other root secrets from offline custody (see
  [Root secrets and offline custody](#root-secrets-and-offline-custody)).

## Recovery order

Restore in priority order — critical infrastructure first, media last.

| Priority | Dataset                                        | B2 bucket                        | Size estimate | Purpose                                                           |
| -------- | ---------------------------------------------- | -------------------------------- | ------------- | ----------------------------------------------------------------- |
| 1        | `backups/truenas-config`                       | `sp3nx0r-backups-truenas-config` | Tiny          | TrueNAS configuration database and secret seed                    |
| 1        | `backups/etcd`                                 | `sp3nx0r-homelab-etcd`           | Tiny          | age-encrypted etcd snapshots (written to B2 by the cluster; PULL) |
| 2        | `homelab/k8s-exports`                          | `sp3nx0r-homelab`                | Small         | Kubernetes NFS PVCs                                               |
| 3        | `homelab/kopia`                                | `sp3nx0r-homelab-kopia`          | Small-medium  | Volsync backup repo (needed to restore iSCSI PVC data)            |
| 4        | `homelab/k8s-iscsi`                            | N/A                              | Small         | iSCSI zvols (do not restore from B2 file sync; use Kopia instead) |
| 5        | `backups/workstations` + `backups/git-bundles` | `sp3nx0r-backups-workstation`    | Medium        | Workstation mirrors and Git bundles                               |
| 6        | `backups/archive`                              | `sp3nx0r-backups-archive`        | Variable      | Long-lived archive data                                           |
| 7        | `media`                                        | `sp3nx0r-media`                  | Large         | Media library (lowest priority, largest download)                 |

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
just ansible init
just ansible nas
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

# etcd snapshots are age-encrypted by the cluster, not rclone crypt: use the raw remote.
# (The Ansible-managed "B2 - homelab-etcd (pull)" task also does this on its own.)
rclone copy b2-raw:sp3nx0r-homelab-etcd /mnt/tank/backups/etcd --progress
```

### Phase 3: Fix ownership

```bash
ssh nas 'sudo chown -R 1000:1000 /mnt/tank/homelab/kopia'
# Other datasets may need ownership fixes depending on your user setup
```

### Phase 4: Rebuild Kubernetes cluster

```bash
# Bootstrap Talos nodes (applies machine config, bootstraps etcd, writes kubeconfig)
just bootstrap talos

# Seed the minimal runtime and Flux (Cilium, CoreDNS, Spegel, cert-manager,
# flux-operator, flux-instance) via helmfile, then hand off to Flux
just bootstrap apps

# Flux reconciles from git and redeploys all apps
# Volsync ReplicationDestinations will restore iSCSI PVC data from the Kopia repo
```

This rebuilds from Git with an empty etcd, which is the right path after total
NAS loss (restored PV bindings would point at zvols that no longer exist). If
the NAS survived and only the cluster was lost, restore etcd instead of
`just bootstrap talos`. That keeps the existing PV bindings, Volsync state, and
certificates. See [Runbook: Restore etcd from a snapshot](runbook-restore-etcd.md).

### Phase 5: Verify

- [ ] All Flux kustomizations healthy: `flux get ks -A`
- [ ] All pods running: `kubectl get pods -A`
- [ ] Volsync ReplicationDestinations completed
- [ ] NFS PVCs accessible
- [ ] Verify the Ansible-managed Cloud Sync PUSH tasks are enabled after restored data is confirmed

## Estimated recovery time

| Component                         | Estimate        | Notes                                    |
| --------------------------------- | --------------- | ---------------------------------------- |
| TrueNAS install + Ansible         | 1-2 hours       | Hardware-dependent                       |
| B2 download (k8s-exports + kopia) | Hours           | Bandwidth-dependent                      |
| B2 download (media)               | Days            | Could be 1TB+, deprioritize              |
| Kubernetes bootstrap              | 30 minutes      | Automated via Talos + Flux               |
| PVC restores via Volsync          | Minutes per PVC | Runs automatically after Flux reconciles |

## Root secrets and offline custody

Almost everything is in Git encrypted with SOPS, so **one age key unlocks the
rest of the chain**, and the chain is only as good as that key's offline copy.
The table lists exactly what a rebuild from zero needs. Items marked
**offline** must exist outside this workstation, the NAS, and the cluster.

| Secret                                                     | Needed for                                                                                                                                                          | Where it lives                                                                                                            | Offline custody                                                                                                                        |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `age.key` (`age1j8au…atgj8`)                               | Decrypting every `*.sops.*` file (including Flux's own `sops-age` Secret, which is encrypted to itself), `topf` reading the Talos bundle, decrypting etcd snapshots | Workstation `/opt/home-ops/age.key` (gitignored); in-cluster `flux-system/sops-age`                                       | **Offline:** password manager (secure note) **and** printed paper copy in a safe or off-site. Optional second recipient (below).       |
| Talos secrets bundle                                       | Machine configs with the same CAs and identity, decrypting Secrets inside an etcd snapshot (`secretboxencryptionsecret`)                                            | Git: `talos/secrets.sops.yaml` (whole file, SOPS)                                                                         | Covered by `age.key` plus a Git clone. Keep a recent `git bundle` in the password manager or on the offline USB.                       |
| `talosconfig`, `kubeconfig`                                | Admin access                                                                                                                                                        | Derived: `topf talosconfig` / `topf kubeconfig` from the bundle                                                           | None needed                                                                                                                            |
| etcd snapshots                                             | [etcd restore](runbook-restore-etcd.md)                                                                                                                             | B2 `sp3nx0r-homelab-etcd`, NAS `tank/backups/etcd` (age-encrypted)                                                        | Covered by `age.key` / paper key                                                                                                       |
| `KOPIA_PASSWORD`                                           | Opening the Volsync Kopia repo (every iSCSI PVC restore)                                                                                                            | Git: `kubernetes/components/sops/cluster-secrets.sops.yaml`                                                               | Covered by `age.key`; also copy to the password manager (without it, the Kopia copy in B2 is unreadable)                               |
| TrueNAS Cloud Sync rclone-crypt password + salt            | Decrypting **every** TrueNAS-pushed B2 bucket (config, k8s-exports, Kopia, media, …)                                                                                | Git: `ansible/inventory/host_vars/hl8/secrets.sops.yml` (`vault_truenas_b2_encryption_password` / `_salt`)                | **Offline:** password manager. This is the only key to the offsite copy of the NAS.                                                    |
| ZFS dataset encryption passphrase                          | Unlocking `tank/backups`, `tank/homelab`, `tank/media`, `tank/scratch` after any NAS reboot or import                                                               | **Not in Git**: prompted by `truenas-configure.yml` / `truenas-unlock.yml`                                                | **Offline:** password manager and paper                                                                                                |
| TrueNAS config backup (`freenas-v1-*.db` + `pwenc_secret`) | Phase 0 restore of the whole TrueNAS config                                                                                                                         | NAS `tank/backups/truenas-config`, B2 `sp3nx0r-backups-truenas-config` (rclone crypt)                                     | Covered by the crypt password. `pwenc_secret` is required to decrypt credentials stored in the DB, so never restore the DB without it. |
| B2 credentials                                             | Downloading anything from B2, managing buckets                                                                                                                      | Git: `ansible/inventory/group_vars/backblaze/secrets.sops.yml` (account-wide key); the B2 console login can mint new keys | **Offline:** B2 account email, password, and 2FA recovery codes in the password manager                                                |
| Cloudflare tokens (DNS, tunnel, TrueNAS ACME)              | external-dns, the public tunnel, NAS certificate                                                                                                                    | Git: `network/cloudflare-dns`, `network/cloudflare-tunnel` secrets; `vault_truenas_cf_api_token`                          | Re-issuable. **Offline:** Cloudflare login and 2FA recovery codes                                                                      |
| GitHub                                                     | Pushing and merging (Flux reads the public repo without a key); `flux-system/github-webhook-token-secret` is regenerable                                            | GitHub account                                                                                                            | **Offline:** GitHub login and 2FA recovery codes                                                                                       |

### Offline custody plan

1. **Password manager** (off-site, synced): one "Homelab break-glass" vault
   with `age.key` contents, the ZFS passphrase, the rclone-crypt password and
   salt, `KOPIA_PASSWORD`, and B2, Cloudflare, and GitHub logins with 2FA
   recovery codes. Keep a link to this section in the vault.
2. **Paper:** print `age.key` (it is one short line) and the ZFS passphrase.
   Store them in a safe or with a trusted person off-site. Re-check yearly that
   it still decrypts (`age -d -i paper.key` on a current etcd snapshot).
3. **Second age recipient (recommended):** generate a separate X25519 key
   offline (`age-keygen`), keep the private key on paper or in the password
   manager, and add its public key:
    - to every `creation_rule` in `.sops.yaml`, then re-wrap all files:
      `fd -e yaml -e yml '\.sops\.' | xargs -n1 sops updatekeys -y`
    - to `AGE_RECIPIENT_PUBLIC_KEY` in
      `kubernetes/apps/system-upgrade/etcd-backup/app/helmrelease.yaml`
      (comma-separated)

    A YubiKey (`age1yubikey1…`, via `age-plugin-yubikey`) can be added to
    `.sops.yaml` too, because SOPS 3.13 supports age plugins. It **cannot** be a
    talos-backup recipient: the scratch image has no plugin binaries and age's
    parser rejects plugin recipients. Use the paper key there.

4. **Git:** keep a `git bundle` of this repo on the offline USB, so a rebuild
   does not depend on GitHub. A copy in `backups/git-bundles` on B2 does not
   remove that need: it is rclone-crypted, and the crypt password lives in a
   SOPS file _inside_ the repo. That loop is why the crypt password must also
   be in the password manager.

Chain check: paper `age.key` + a Git clone (GitHub or the offline bundle) →
SOPS files → rclone-crypt password → B2 → TrueNAS config + Kopia repo → Talos
bundle + etcd snapshots → cluster. Only the ZFS passphrase and the external
account logins sit outside Git, and they are in the password manager.

## Important notes

- **iSCSI zvols are block devices** — they won't restore cleanly from B2 file sync. Use Volsync/Kopia to restore iSCSI PVC data instead.
- **B2 egress is metered** — first 1 GB/day free, then $0.01/GB. Budget for egress costs on large restores.
- **Suspend Cloud Sync PUSH during restore** if tasks were recreated or restored as enabled. Resume only after verifying restored data, or incomplete local data can be pushed back to B2.

## TODO

- [ ] Estimate total B2 dataset size and calculate egress cost
- [ ] Test partial restore of priority datasets
- [x] Document Talos bootstrap procedure or link to existing docs ([etcd restore](runbook-restore-etcd.md), Phase 4)
- [x] Document the root-secret chain and offline custody ([above](#root-secrets-and-offline-custody))
- [ ] Populate the break-glass password-manager vault and print the paper keys
- [ ] Add a second (offline) age recipient to `.sops.yaml` and the etcd-backup CronJob
