#!/usr/bin/env bash
set -uo pipefail

DATASETS=("tank/backups" "tank/media" "tank/homelab" "tank/scratch")
HOST="truenas_admin@192.168.5.40"

read -s -p "Dataset passphrase: " PASSPHRASE
echo

ITEMS=""
for ds in "${DATASETS[@]}"; do
  [ -n "$ITEMS" ] && ITEMS+=","
  ITEMS+="{\"name\": \"$ds\", \"passphrase\": \"$PASSPHRASE\"}"
done
PAYLOAD="{\"datasets\": [$ITEMS], \"recursive\": true}"

echo "Unlocking datasets on hl8..."
JOB_ID=$(ssh "$HOST" "sudo midclt call pool.dataset.unlock tank '$PAYLOAD'")
echo "Waiting for job $JOB_ID..."
ssh "$HOST" "sudo midclt call core.job_wait $JOB_ID" >/dev/null 2>&1 || true

RESULT=$(ssh "$HOST" "sudo midclt call core.get_jobs '[[\"id\",\"=\",$JOB_ID]]'")

python3 -c "
import json, sys
job = json.loads('''$RESULT''')[0]
result = job.get('result', {})
unlocked = result.get('unlocked', [])
failed = result.get('failed', {})
for u in unlocked:
    print(f'  Unlocked: {u}')
for k, v in failed.items():
    print(f'  FAILED: {k} - {v[\"error\"]}')
if failed:
    sys.exit(1)
if not unlocked:
    print('  Nothing to unlock (already unlocked?)')
print('Done.')
"
