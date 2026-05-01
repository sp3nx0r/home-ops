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

```bash
# Decrypt B2 credentials from SOPS and export for AWS CLI
eval $(sops -d ansible/inventory/group_vars/backblaze/secrets.sops.yml \
  | yq -r '"export AWS_ACCESS_KEY_ID=\(.b2_access_key_id)\nexport AWS_SECRET_ACCESS_KEY=\(.b2_secret_access_key)"')
export AWS_ENDPOINT_URL=https://s3.us-west-000.backblazeb2.com

# Verify access
aws s3 ls s3://sp3nx0r-truenas/ --summarize --human-readable | head -5
```

If you don't have `sops`/`yq` available, export manually:

```bash
export AWS_ACCESS_KEY_ID=<your-key-id>
export AWS_SECRET_ACCESS_KEY=<your-secret>
export AWS_ENDPOINT_URL=https://s3.us-west-000.backblazeb2.com
```

## Procedures

### Find available versions of a file

```bash
aws s3api list-object-versions \
  --bucket sp3nx0r-truenas \
  --prefix "path/to/file.txt" \
  --max-keys 20

# Look for entries where IsLatest=false — those are noncurrent (previous) versions
# Note the VersionId and LastModified to identify the version you want
```

### Restore a single file

```bash
aws s3api get-object \
  --bucket sp3nx0r-truenas \
  --key "path/to/file.txt" \
  --version-id "<version-id>" \
  ./restored-file.txt
```

### Restore a directory (list and batch download)

```bash
# List all objects under a prefix with versions
aws s3api list-object-versions \
  --bucket sp3nx0r-truenas \
  --prefix "homelab/k8s-exports/some-app/" \
  --query 'Versions[?IsLatest==`false`].[Key,VersionId,LastModified]' \
  --output table

# Download each noncurrent version — script for bulk restore:
aws s3api list-object-versions \
  --bucket sp3nx0r-truenas \
  --prefix "homelab/k8s-exports/some-app/" \
  --query 'Versions[?IsLatest==`false`].[Key,VersionId]' \
  --output text | while read KEY VID; do
    mkdir -p "$(dirname "restored/$KEY")"
    aws s3api get-object \
      --bucket sp3nx0r-truenas \
      --key "$KEY" \
      --version-id "$VID" \
      "restored/$KEY"
    echo "Restored: $KEY"
done
```

### Restore using rclone (alternative for large restores)

```bash
# rclone doesn't natively restore noncurrent versions
# Use aws CLI for version-specific restores, or:
# 1. Remove the delete markers to "undelete" files
# 2. Then rclone sync from B2 back to NAS

# Remove delete markers for a prefix
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
```

## Important notes

- **30-day window**: Noncurrent versions are permanently deleted after 30 days by the lifecycle rule. Act quickly.
- **B2 egress costs**: Downloading from B2 is free for the first 1 GB/day, then $0.01/GB. Large restores may incur costs.
- **Cloud Sync may re-delete**: If you restore files to TrueNAS and the original issue isn't fixed, the next Cloud Sync PUSH will overwrite your restoration. Fix the root cause first, or pause Cloud Sync during recovery.

## TODO

- [ ] Script to list all noncurrent versions within a specific date range
- [ ] Estimate download speed and RTO for various dataset sizes
- [ ] Test bulk restore of a real directory
