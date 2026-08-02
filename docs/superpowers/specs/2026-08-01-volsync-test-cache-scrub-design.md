# VolSync Test Cache Scrub Design

**Status:** Approved for planning

## Goal

Clear the disposable Kopia cache used by the `default/volsync-test`
ReplicationSource once per day so its inode usage cannot accumulate into a
PersistentVolume alert.

## Root cause

`KubePersistentVolumeInodesFillingUp` fired continually against
`default/volsync-src-volsync-test-cache`. Direct inspection of the cache PVC
showed inode — not byte — exhaustion:

- `df -i` reported 129,386 / 131,072 inodes used (99%) on the 2 GiB ext4
  volume (ext4 allocates ~1 inode per 16 KiB, so 2 GiB caps at 131,072).
- `/cache/index-blobs/` held ~93,000 tiny files, dwarfing everything else.

The mechanism: all ReplicationSources share one Kopia repository on NFS, and
every hourly mover caches that repository's index blobs locally. Kopia evicts
its local cache **by total bytes, never by file count** (metadata cache limit
here is ~1,433 MB). The individual index-blob files are far smaller than that
byte budget, so stale entries are never swept and the file count climbs for as
long as the cache PVC survives — eventually exhausting inodes while byte usage
stays low. Shared-repository index-blob churn (maintenance logs reported
2,650–3,357 index blobs even after full maintenance) keeps the working set
large, so the cache refills quickly.

The existing zero-byte scrub init container only removes corruption artifacts
(files left by an unclean mover exit); it does not touch these non-empty
index-blob files and therefore does not address this alert.

## Scope and constraints

- Only the controller-owned PVC `default/volsync-src-volsync-test-cache` is
  eligible for deletion.
- The live `volsync-test` source PVC, VolumeSnapshots, ReplicationSource, and
  shared Kopia repository are out of scope and must not be changed by the
  scrubber.
- The cache is an optimization only. VolSync recreates the controller-owned
  PVC when it is absent; the first following backup can be slower while Kopia
  rebuilds its cache.
- The VolSync source starts on the hour. The daily scrub runs at 00:30 in
  `America/Chicago`, leaving a 20-minute buffer after the preceding scheduled
  source run.

## Approaches considered

1. Delete the cache PVC through a dedicated CronJob. This is selected because
   VolSync owns and recreates the PVC, deletion is atomic, and no additional
   workload needs to attach the ReadWriteOnce volume.
2. Attach the PVC to a cleanup pod and erase files. This was rejected because
   it adds iSCSI attachment scheduling and partial-cleanup failure modes.
3. Silence the inode alert. This was rejected because it would hide a real
   capacity constraint rather than renewing the disposable cache.
4. Grow the cache PVC alone for more inodes. This is retained as a complement,
   not a fix: a larger ext4 volume provides proportionally more inodes, but
   byte-based eviction means the file count still grows unbounded, so it only
   delays the alert without the daily scrub.

## Complementary mitigation: cache capacity

Raise `VOLSYNC_CAPACITY` for `volsync-test` from `2Gi` to `4Gi` in its
`ks.yaml`. This roughly doubles the cache's inode budget (~131k to ~262k),
giving headroom above the observed peak so a single missed or slow scrub does
not immediately re-trip the alert. It is paired with the daily scrub because,
on its own, a bigger byte budget also lets Kopia retain more index-blob files
before byte-eviction, which does not solve the inode growth.

## Design

Add a `volsync-test-cache-scrub.yaml` manifest to
`kubernetes/apps/default/volsync-test/app/` and include it in that directory's
`kustomization.yaml`. The manifest contains four resources:

1. `ServiceAccount/volsync-test-cache-scrub`.
2. A namespaced `Role` allowing only:
   - `get` on `batch/jobs/volsync-src-volsync-test`, to determine whether the
     VolSync mover is active;
   - `get` and `delete` on
     `persistentvolumeclaims/volsync-src-volsync-test-cache`, to remove and
     confirm recreation of the sole target.
3. A `RoleBinding` attaching that Role to the ServiceAccount.
4. A `CronJob/volsync-test-cache-scrub` using a digest-pinned `kubectl` image.

The CronJob uses `timeZone: America/Chicago`, `schedule: "30 0 * * *"`,
`concurrencyPolicy: Forbid`, a five-minute active deadline, no retry backoff,
and one-day TTL cleanup. Its container executes the following sequence:

1. Read `volsync-src-volsync-test.status.active`. If it is nonzero, log the
   skip and exit successfully without deleting anything.
2. Delete `volsync-src-volsync-test-cache` with `--ignore-not-found`.
3. Poll for the PVC to be recreated and wait for it to reach `Bound`, failing
   after five minutes if the VolSync controller does not restore the cache.

The job is intentionally blocked only by an active mover rather than the mere
presence of the completed Job resource. This lets it run after a successful
hourly backup while still preventing deletion of a cache attached to a mover.

## Error handling and observability

- A concurrent VolSync backup produces a successful skip, leaving the cache
  for the next daily schedule.
- A Kubernetes API, PVC deletion, or recreation failure makes the CronJob
  fail, so it is inspectable with normal Job status and logs.
- The existing inode alert stays enabled. It is the guardrail for an unusually
  rapid cache rebuild or a failed scrub.

## Validation

1. Render and schema-validate the Flux application manifests.
2. Reconcile the `volsync-test` Flux Kustomization.
3. Create a one-off Job from the CronJob and inspect its logs.
4. Verify that the target cache PVC was deleted, recreated by VolSync, and is
   `Bound` at its configured 4 GiB capacity.
5. Trigger or await the next scheduled VolSync source backup and verify a
   successful mover result with a freshly populated cache.
