# Ansible — Infrastructure Configuration

Declarative configuration for infrastructure that lives outside
the Kubernetes cluster.

## Playbooks

| Playbook | Target | Description |
|----------|--------|-------------|
| `truenas-configure.yml` | HL8 NAS (TrueNAS SCALE 25.10) | Full NAS config via [arensb.truenas](https://github.com/arensb/ansible-truenas) + `midclt` |
| `backblaze-configure.yml` | Backblaze B2 (S3 API) | Bucket versioning + lifecycle rules for offsite backups |

---

## Backblaze B2

Manages the `sp3nx0r-truenas` B2 bucket used by TrueNAS Cloud Sync for offsite
backups. Runs locally against B2's S3-compatible API.

### What it configures

| Setting | Value |
|---------|-------|
| Versioning | Enabled (required for lifecycle rules) |
| Noncurrent version expiration | 30 days (protects against ransomware/accidental deletion propagation) |
| Abort incomplete multipart uploads | 7 days |

### Secrets

B2 application key credentials are stored in
`inventory/group_vars/backblaze/secrets.sops.yml`:

| Variable | Purpose |
|----------|---------|
| `b2_access_key_id` | B2 application key ID |
| `b2_secret_access_key` | B2 application key secret |

Generate a B2 application key scoped to the bucket:
1. Log into Backblaze → App Keys → Add a New Application Key
2. Restrict to bucket: `sp3nx0r-truenas`
3. Allow: `listBuckets`, `readBuckets`, `writeBuckets`, `listFiles`, `readFiles`, `writeFiles`
4. Decrypt and update the secrets file:
   ```bash
   sops ansible/inventory/group_vars/backblaze/secrets.sops.yml
   ```

### Usage

```bash
task ansible:backblaze              # apply
task ansible:backblaze:dry-run      # check mode
task ansible:backblaze -- --tags versioning   # just versioning
task ansible:backblaze -- --tags lifecycle    # just lifecycle rules
```

### Purge previous versions

Use `backblaze-purge-versions.yml` for one-off cleanup of noncurrent object
versions under a bucket prefix. It is dry-run by default and requires an
explicit prefix:

```bash
task ansible:backblaze:purge-versions -- -e b2_purge_prefix=media/downloads/qbittorrent
task ansible:backblaze:purge-versions -- -e b2_purge_prefix=media/downloads/qbittorrent -e b2_purge_dry_run=false
```

Delete markers are not removed unless requested:

```bash
task ansible:backblaze:purge-versions -- \
  -e b2_purge_prefix=media/downloads/qbittorrent \
  -e b2_purge_delete_markers=true \
  -e b2_purge_dry_run=false
```

### Delete a prefix completely

Use `backblaze-delete-prefix.yml` when you want to remove a bucket path
entirely, including current versions, previous versions, and delete markers.
It is dry-run by default and requires an explicit prefix:

```bash
task ansible:backblaze:delete-prefix -- -e b2_delete_prefix=backups/vassago
task ansible:backblaze:delete-prefix -- -e b2_delete_prefix=backups/vassago -e b2_delete_dry_run=false
```

---

## TrueNAS HL8 NAS

Declarative configuration for the HL8 NAS running TrueNAS SCALE 25.10 using the
[arensb.truenas](https://github.com/arensb/ansible-truenas) Ansible collection
and direct `midclt` API calls for features the collection doesn't cover.

## What Ansible manages

| Tag | What it configures |
|-----|--------------------|
| `system` | Hostname, domain, timezone (`America/Chicago`), console messages, usage collection, console password |
| `ntp` | Cloudflare NTP servers (`162.159.200.1`, `162.159.200.123`) |
| `sysctl` | Security hardening (rp_filter, ICMP, syncookies) + 10GbE/NFS performance (BBR, socket buffers, sunrpc slots) |
| `users` | Admin and service accounts — SSH keys, sudo, group membership for RBAC |
| `services` | NFS, SSH |
| `datasets` | ZFS dataset creation + properties (compression, recordsize, atime, sync) |
| `nfs` | NFS exports for Kubernetes PVs, media, and backups |
| `snapshots` | Periodic ZFS snapshot tasks |
| `smart` | SMART test schedules (via cron — TrueNAS 25.10 removed the `smart.test` API) |
| `scrub` | Pool scrub task |
| `ups` | CyberPower CP1500PFCLCD as NUT master (port 3493 for Talos clients) |

## What requires manual setup (one-time)

1. **Install TrueNAS SCALE** on the HL8
2. **Create pool** — Storage → Create Pool
   - Phase 1: `tank`, RAIDZ1, all 5×4TB disks
   - Phase 2: `tank`, 2× RAIDZ2 vdevs, 4 disks each
3. **Enable SSH** — System → Services → SSH → enable + start
4. **Create `truenas_admin` user** in UI with:
   - Your SSH public key
   - Passwordless sudo (`ALL`) — set via Credentials → Users → truenas_admin → Allowed sudo commands with no password → `ALL`
   - Ansible manages this user afterward
5. **Plug UPS USB cable** — CyberPower CP1500PFCLCD USB into the HL8
6. **Create Prometheus API key** — After Ansible adds the `prometheus` user to
   the `truenas_readonly_administrators` group, create the key via SSH:
   ```bash
   ssh truenas_admin@192.168.5.40 \
     "sudo midclt call api_key.create '{\"name\": \"prometheus-exporter\", \"username\": \"prometheus\"}'"
   ```
   Save the returned `key` value into the SOPS-encrypted Kubernetes
   secret at `kubernetes/apps/o11y/truenas-exporter/app/secret.sops.yaml`.
7. **Enable 2FA for the web UI** — Per-user TOTP setup, then global enforcement:
   - Credentials → Users → `truenas_admin` → Edit → Two Factor Authentication → enable, scan QR code, confirm
   - Credentials → 2FA → Enable Two Factor Authentication
   - Leave SSH 2FA disabled (SSH uses key-based auth)

## TODO

- [ ] Configure syslog forwarding to Loki (`system.advanced.update` syslogservers)

## Prerequisites

```bash
# Install everything via Taskfile (uses uv + venv)
task ansible:init
```

> **Note:** The `ansible:init` task patches a known bug in `arensb.truenas`
> 1.14.4 by removing a broken action plugin (`filesystem.py`) that causes
> import errors.

### SSH access

```bash
# Verify connectivity
ssh truenas_admin@192.168.5.40 'echo ok'
```

The playbook uses the SSH key configured in `vars.yml`. If you need to bootstrap with a different key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/truenas_ed25519 -C "ansible@truenas"
# Add the public key in TrueNAS UI:
# Credentials → Local Users → truenas_admin → SSH Public Key
```

### Secrets

Sensitive values are stored in `inventory/host_vars/hl8/secrets.sops.yml`,
encrypted with age via SOPS. The file contains:

| Variable | Purpose |
|----------|---------|
| `vault_truenas_admin_email` | Admin user email |
| `vault_truenas_domain` | Domain name |
| `vault_truenas_admin_password` | Admin user password |
| `vault_truenas_ups_monpwd` | NUT monitor password (for Talos clients) |

Decryption requires the age key at the repo root (`age.key`) or
`~/.config/sops/age/keys.txt`. The SOPS config (`.sops.yaml`) uses
`encrypted_regex: ^(data|stringData)$` for Kubernetes secrets and
`mac_only_encrypted` for Ansible vars files.

## Usage

```bash
# Full run — configure everything
task ansible:configure

# Run specific sections only
task ansible:configure -- --tags system
task ansible:configure -- --tags ntp
task ansible:configure -- --tags sysctl
task ansible:configure -- --tags users
task ansible:configure -- --tags services
task ansible:configure -- --tags datasets
task ansible:configure -- --tags nfs
task ansible:configure -- --tags snapshots
task ansible:configure -- --tags smart
task ansible:configure -- --tags scrub
task ansible:configure -- --tags ups

# Dry run — see what would change
task ansible:configure:dry-run

# Lint
task ansible:lint
```

## Known quirks

- **`arensb.truenas.user` module** sends `password: ''` on update, which
  TrueNAS 25.x rejects. The playbook uses `midclt call user.create/update`
  directly instead, omitting `password` and `home` from update payloads.
- **SMART tests** are configured as cron jobs (`midclt call cronjob.create`)
  because TrueNAS 25.10 removed the `smart.test` API.
- **UPS driver format** — TrueNAS requires the full `driver$model` string
  (e.g., `usbhid-ups$CP1500EPFCLCD`), not just the driver name. Use
  `midclt call ups.driver_choices` to find valid values.
- **User home directories** — TrueNAS 25.x validates that home paths start
  with `/mnt/` on update. The playbook only sets `home` during user creation,
  not on subsequent updates.

## Phase migration (4TB → 18TB)

When replacing the temporary drives with permanent ones:

1. Back up data to external SSD
2. Destroy pool in TrueNAS UI, swap drives
3. Create new pool: `tank`, 2× RAIDZ2 vdevs (4 disks each)
4. Update `ansible/inventory/host_vars/hl8/vars.yml`:
   ```yaml
   truenas_phase: phase2
   ```
5. Re-run the playbook:
   ```bash
   task ansible:configure
   ```

This creates the additional Phase 2 datasets (ceph backups, client backups,
VM images) on top of the common set.

## Directory structure

```
ansible/
├── .ansible-lint                        # Lint config (excludes secrets.sops.yml)
├── .venv/                               # Python virtualenv (git-ignored)
├── ansible.cfg                          # Ansible settings + SOPS integration
├── requirements.yml                     # Collection deps
├── inventory/
│   ├── hosts.yml                        # Inventory (hl8 + backblaze localhost)
│   ├── host_vars/
│   │   └── hl8/
│   │       ├── vars.yml                 # TrueNAS configuration variables
│   │       └── secrets.sops.yml         # Encrypted TrueNAS secrets (age/SOPS)
│   └── group_vars/
│       └── backblaze/
│           ├── vars.yml                 # B2 bucket config (name, lifecycle, etc.)
│           └── secrets.sops.yml         # Encrypted B2 credentials (age/SOPS)
├── playbooks/
│   ├── truenas-configure.yml            # TrueNAS playbook
│   └── backblaze-configure.yml          # Backblaze B2 playbook
└── README.md
```
