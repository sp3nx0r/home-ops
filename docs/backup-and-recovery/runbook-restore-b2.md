# Runbook: Restore files from Backblaze B2

## When to use

- A file or directory was accidentally deleted or overwritten on TrueNAS
- The TrueNAS Cloud Sync (SYNC mode) propagated the deletion/corruption to B2
- The incident was discovered within 30 days (noncurrent version retention window)
- ZFS snapshots have already rolled past the incident (>24h ago)

## Prerequisites

- `aws` CLI or `b2` CLI installed
- B2 application key with `listBuckets`, `readBuckets`, `listFiles`, `readFiles` on `sp3nx0r-truenas`
- Or use `rclone` configured with B2 backend

## Configure CLI

All data restores **must** go through rclone with a crypt remote (see below). The `aws` CLI is only needed for raw bucket browsing and version-level operations (listing noncurrent versions, removing delete markers).

```bash
# Decrypt B2 credentials from SOPS and export for AWS CLI
eval $(sops -d ansible/inventory/group_vars/backblaze/secrets.sops.yml \
  | yq -r '"export AWS_ACCESS_KEY_ID=\(.b2_access_key_id)\nexport AWS_SECRET_ACCESS_KEY=\(.b2_secret_access_key)"')
export AWS_ENDPOINT_URL=https://s3.us-west-000.backblazeb2.com

# Browse raw bucket contents (encrypted .bin files)
aws s3 ls s3://sp3nx0r-truenas/ --summarize --human-readable | head -5
```

## Understanding the rclone crypt layer

All Cloud Sync tasks have **client-side encryption enabled** via rclone crypt. This means:

- **File contents** are encrypted with AES-256 before leaving the NAS. Raw downloads from B2 are unreadable without the encryption password and salt.
- **Filenames** are **not** encrypted (`filename_encryption: false`), so directory structure and paths are visible in B2. However, files have a `.bin` extension appended by rclone crypt (e.g., `media/movies/something.mkv` appears as `media/movies/something.mkv.bin` in B2).
- **You cannot restore by downloading files directly from the B2 console** — the `.bin` files are encrypted blobs. You must use `rclone` with the matching crypt config to decrypt on download.

The encryption password and salt are stored in the TrueNAS Cloud Sync task config and in the Ansible vars at `host_vars/hl8/secrets.sops.yml` (`vault_truenas_b2_encryption_password`, `vault_truenas_b2_encryption_salt`).

## Procedures

### Configure rclone with crypt remote

Restores **must** go through rclone with a crypt overlay to decrypt the `.bin` files. Get the encryption credentials from SOPS:

```bash
# Decrypt the encryption password and salt
sops -d ansible/inventory/host_vars/hl8/secrets.sops.yml \
  | yq -r '"password: \(.vault_truenas_b2_encryption_password)\nsalt: \(.vault_truenas_b2_encryption_salt)"'
```

Then configure rclone (or edit `~/.config/rclone/rclone.conf` directly):

```ini
[b2-raw]
type = b2
account = <B2_KEY_ID>
key = <B2_SECRET>

[b2]
type = crypt
remote = b2-raw:sp3nx0r-truenas
password = <OBSCURED_PASSWORD>
password2 = <OBSCURED_SALT>
filename_encryption = off
```

To obscure the password and salt for the rclone config:

```bash
rclone obscure '<vault_truenas_b2_encryption_password>'
rclone obscure '<vault_truenas_b2_encryption_salt>'
```

### Browse remote files (decrypted view)

```bash
# List top-level directories
rclone ls b2: --max-depth 1

# List files in a specific path (shows real filenames, not .bin)
rclone ls b2:media/movies/
```

### Restore a single file

```bash
rclone copy b2:path/to/file.txt ./restored/ --progress
```

### Restore a directory

```bash
rclone copy b2:homelab/k8s-exports/some-app/ ./restored/some-app/ --progress
```

### Restore directly to TrueNAS

```bash
# From the NAS (if rclone is configured there)
ssh nas
rclone copy b2:homelab/k8s-exports /mnt/tank/homelab/k8s-exports --progress

# Or for a full dataset restore
rclone sync b2:backups /mnt/tank/backups --progress
```

### Restore a previous version (noncurrent)

rclone doesn't natively browse noncurrent versions. Use the `aws` CLI against the raw (unencrypted-filename) bucket to find versions, then undelete before pulling via rclone:

```bash
# List noncurrent versions of a file (uses .bin name as stored in B2)
aws s3api list-object-versions \
  --bucket sp3nx0r-truenas \
  --prefix "path/to/file.txt.bin" \
  --max-keys 20

# Remove delete markers to "undelete" files at a prefix
aws s3api list-object-versions \
  --bucket sp3nx0r-truenas \
  --prefix "path/to/restore/" \
  --query 'DeleteMarkers[?IsLatest==`true`].[Key,VersionId]' \
  --output text | while read KEY VID; do
    aws s3api delete-object \
      --bucket sp3nx0r-truenas \
      --key "$KEY" \
      --version-id "$VID"
    echo "Undeleted: $KEY"
done

# Now pull via rclone to get decrypted content
rclone copy b2:path/to/restore/ ./restored/ --progress
```

## Important notes

- **30-day window**: Noncurrent versions are permanently deleted after 30 days by the lifecycle rule. Act quickly.
- **B2 egress costs**: Downloading from B2 is free for the first 1 GB/day, then $0.01/GB. Large restores may incur costs.
- **Cloud Sync may re-delete**: If you restore files to TrueNAS and the original issue isn't fixed, the next Cloud Sync PUSH will overwrite your restoration. Fix the root cause first, or pause Cloud Sync during recovery.
- **Encryption credentials are critical**: Without the rclone crypt password and salt, B2 data is unrecoverable. These are stored in `ansible/inventory/host_vars/hl8/secrets.sops.yml` (encrypted with age) and in each TrueNAS Cloud Sync task config.

## TODO

- [ ] Script to list all noncurrent versions within a specific date range
- [ ] Estimate download speed and RTO for various dataset sizes
- [ ] Test bulk restore of a real directory
