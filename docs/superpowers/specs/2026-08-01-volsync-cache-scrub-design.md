# VolSync Cache Scrub Design

**Status:** Implemented

## Goal

Clear the disposable Kopia mover cache for every VolSync-backed app once per
day so its inode usage cannot accumulate into a PersistentVolume alert. The
scrub ships in the shared `components/volsync` component so it applies fleet
wide, not just to the `volsync-test` canary that first tripped the alert.

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

`volsync-test` (2 GiB cache) tripped first, but the mechanism is identical for
every app that opts into `components/volsync`. The existing zero-byte scrub
init container only removes corruption artifacts (files left by an unclean
mover exit); it does not touch these non-empty index-blob files and therefore
does not address this alert.

## Scope and constraints

- Only each app's controller-owned cache PVC `volsync-src-${APP}-cache` is
  eligible for deletion.
- The live `${APP}` source PVC, VolumeSnapshots, ReplicationSource, and shared
  Kopia repository are out of scope and must not be changed by the scrubber.
- The cache is an optimization only. VolSync recreates the controller-owned
  PVC (it carries an owner reference to the ReplicationSource) on the next
  scheduled sync; the first following backup can be slower while Kopia rebuilds
  its cache.
- VolSync sources start on the hour. The daily scrub is scheduled at 00:30 in
  `America/Chicago`; a jitter init container then adds up to 15 minutes, so the
  fleet's scrubs land between 00:30 and 00:45 — after the preceding hourly
  source run and well before the next one.

## Approaches considered

1. Delete the cache PVC through a per-app CronJob shipped in the shared
   component. Selected: VolSync owns and recreates the PVC, deletion is atomic,
   no extra workload needs to attach the ReadWriteOnce volume, and templating
   with `${APP}` covers the whole fleet from one manifest.
2. Attach the PVC to a cleanup pod and erase files. Rejected: it adds iSCSI
   attachment scheduling and partial-cleanup failure modes.
3. Silence the inode alert. Rejected: it would hide a real capacity constraint
   rather than renewing the disposable cache.
4. Grow the cache PVC alone for more inodes. Retained as an optional
   per-app complement, not a fix: a larger ext4 volume provides proportionally
   more inodes, but byte-based eviction means the file count still grows
   unbounded, so it only delays the alert without the daily scrub.

## Complementary mitigation: cache capacity

Apps may raise `VOLSYNC_CAPACITY` for extra inode headroom so a single missed
or slow scrub does not immediately re-trip the alert. `volsync-test` is bumped
from `2Gi` to `4Gi` (~131k to ~262k inodes) as the reference. This is optional
because the daily scrub is the actual bound; a bigger byte budget on its own
also lets Kopia retain more index-blob files before eviction.

## Design

`kubernetes/components/volsync/cache-scrub.yaml` is added to the component's
`kustomization.yaml`, so every app that includes `components/volsync` renders a
scrub instance named `${APP}-cache-scrub`. The manifest contains four
resources, all templated with `${APP}` and namespaced by the app's Flux
`targetNamespace`:

1. `ServiceAccount/${APP}-cache-scrub`.
2. A namespaced `Role` allowing only:
   - `get` on `batch/jobs/volsync-src-${APP}`, to determine whether the VolSync
     mover is active;
   - `get` and `delete` on
     `persistentvolumeclaims/volsync-src-${APP}-cache`.
3. A `RoleBinding` attaching that Role to the ServiceAccount. The subject omits
   an explicit namespace; Flux's namespace transformer sets it to the app's
   `targetNamespace`.
4. A `CronJob/${APP}-cache-scrub` using a digest-pinned `kubectl` image. It
   runs in its own namespace via the `POD_NAMESPACE` downward-API value, so no
   namespace is hardcoded.

The CronJob uses `timeZone: America/Chicago`, `schedule: "30 0 * * *"`,
`concurrencyPolicy: Forbid`, no retry backoff, one-day TTL cleanup, and a
20-minute active deadline (`activeDeadlineSeconds: 1200`) that covers the
jitter sleep plus the delete and poll.

A `jitter` init container runs first and sleeps `$(shuf -i 0-900 -n 1)`
seconds, spreading the fleet's ~20 cache-PVC deletes across a window instead of
firing them all at 00:30. This mirrors the `volsync-mover-jitter` init
container used for the movers; because that MutatingAdmissionPolicy only
matches `volsync-src-*` Jobs, the scrub Jobs (`${APP}-cache-scrub`) carry the
jitter inline instead. (`$(...)` command substitution is left untouched by
Flux's `envsubst`, which only rewrites the `${VAR}` form.)

The main container then executes:

1. Read `volsync-src-${APP}.status.active`. If it is present and nonzero, log
   the skip and exit `0` without deleting anything.
2. Delete `volsync-src-${APP}-cache` with `--ignore-not-found --wait=false`.
3. Best-effort poll for up to two minutes for the PVC to return to `Bound`,
   then exit `0` regardless.

The mover-active guard prevents marking a cache in active use for deletion.
(`pvc-protection` would defer the actual delete anyway, but the guard avoids an
unnecessary mid-sync cache rebuild.)

### Flux substitution safety

Flux's postBuild `envsubst` rewrites the `${VAR}` brace form and leaves the
bare `$var` form untouched. The script therefore uses `${APP}` (intended
substitution) for resource names and the bare `$var` form for every shell
variable. An earlier draft used `${mover_active:-0}`, which Flux collapsed to
its default `0`, permanently defeating the guard (`if [ "0" != "0" ]`). The
regression test asserts that the only `${...}` token in the component is
`${APP}`.

## Error handling and observability

- A concurrent VolSync backup produces a successful skip, leaving the cache for
  the next daily schedule.
- Because VolSync recreates the cache lazily on the next scheduled sync rather
  than immediately, a not-yet-recreated PVC is expected and the job exits `0`
  after logging it. A genuine Kubernetes API or deletion error still fails the
  job for normal Job-status inspection.
- The existing inode alert stays enabled. It is the guardrail for an unusually
  rapid cache rebuild or a failed scrub.

## Validation

1. Render and schema-validate the Flux manifests (`kubectl kustomize` +
   `kubeconform`).
2. Build representative apps across namespaces with `flux-local` (default,
   o11y, media) and confirm `${APP}` substitution, correct per-app resource and
   RoleBinding subject namespaces, and that no shell variable was rewritten by
   envsubst.
3. `bash tests/volsync-cache-scrub.sh` — enforces the CronJob contract,
   least-privilege RBAC, the mover-active guard, namespace-agnostic operation,
   the single jitter init container, and Flux substitution safety.
4. After rollout: create a one-off Job from a CronJob, inspect its logs, and
   verify the target cache PVC is deleted and later restored `Bound` by VolSync
   on the next sync with a freshly populated cache.
