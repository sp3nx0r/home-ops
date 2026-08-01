# VolSync Test Cache Scrub Design

**Status:** Approved for planning

## Goal

Clear the disposable Kopia cache used by the `default/volsync-test`
ReplicationSource once per day so its inode usage cannot accumulate into a
PersistentVolume alert.

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
   `Bound` at its configured 2 GiB capacity.
5. Trigger or await the next scheduled VolSync source backup and verify a
   successful mover result with a freshly populated cache.
