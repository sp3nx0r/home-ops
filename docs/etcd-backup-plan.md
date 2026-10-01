# etcd snapshot backups and root-secret recovery chain

Status: **implemented in the draft PR; not applied.** It closes finding B1 (no
etcd snapshots / no Talos secrets export) and the offline-copy half of S12
(single age key, no offline copy) from the SRE and security evaluation.

Related docs:

- [Runbook: Restore etcd from a snapshot](backup-and-recovery/runbook-restore-etcd.md)
- [Runbook: Full NAS disaster recovery](backup-and-recovery/runbook-disaster-recovery.md), which now includes the root-secret inventory and offline custody plan
- [Backup strategy](backup-and-recovery/backup-strategy.md)

## Summary

| Decision         | Choice                                                                                                                                                                                                                                                                                                                          |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tool             | Official [`siderolabs/talos-backup`][tb], run by a CronJob that is deployed with app-template                                                                                                                                                                                                                                   |
| Talos API access | A Talos `ServiceAccount` CR requesting only `os:etcd:backup`, **inside the existing `system-upgrade` namespace**. The Talos patch adds `os:etcd:backup` to `allowedRoles`; the namespace list stays the same.                                                                                                                   |
| Target           | Upload straight to Backblaze B2 bucket `sp3nx0r-homelab-etcd`. TrueNAS then mirrors it back into `tank/backups/etcd` with a Cloud Sync PULL.                                                                                                                                                                                    |
| Encryption       | zstd, then age, done inside the pod before upload. The recipient is the repo's SOPS key (`age1j8au…atgj8`); a second, offline paper-key recipient is recommended.                                                                                                                                                               |
| Schedule         | Every 6h (`15 */6 * * *`, America/Chicago)                                                                                                                                                                                                                                                                                      |
| Retention        | B2: hide current versions after 30 days, delete one day later. NAS: the SYNC mirror follows B2 (30 days), plus the hourly `tank/backups` ZFS snapshots (24h).                                                                                                                                                                   |
| Monitoring       | `EtcdBackupStale` (last success older than 12h, i.e. 2× the interval), `EtcdBackupNeverSucceeded`, and `EtcdBackupOffsiteStale` (newest B2 object older than 13h, from backblaze-exporter). The existing `KubeJobFailed` rule covers individual failed runs. All three alerts are `severity: warning`, which routes to Discord. |

## Research

### siderolabs/talos-backup

- **Version.** The last tag is `v0.1.0-beta.3` (2025-02-10). `main` has since
  moved on: S3 client switched from aws-sdk-go-v2 to minio-go "for compatibility
  with S3 compatible providers" ([0b3984d]), zstd compression ([3022fec]),
  multiple recipients ([38dad7c]), all age recipient types ([6f0422e]), and
  path-style addressing ([b9fd478], 2026-04-28). CI publishes every `main` commit
  to `ghcr.io/siderolabs/talos-backup`; `latest` currently resolves to
  `v0.1.0-beta.3-10-gb9fd478@sha256:7fc186ff…ae6c`, which is the build pinned
  here. It is a multi-arch (amd64/arm64) `FROM scratch` image with entrypoint
  `/talos-backup`.
- **Config** (env vars, see [`pkg/config/service.go`][svc]): `CUSTOM_S3_ENDPOINT`,
  `BUCKET`, `AWS_REGION`, `S3_PREFIX` (defaults to the cluster name),
  `CLUSTER_NAME` (defaults to the talosconfig context), `USE_PATH_STYLE`,
  `ENABLE_COMPRESSION`, `DISABLE_ENCRYPTION`, and `AGE_RECIPIENT_PUBLIC_KEY`
  (comma-separated). `AGE_X25519_PUBLIC_KEY` is deprecated. Credentials come
  from the minio chain: `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, IAM, or a
  credentials file.
- **Non-AWS S3 / B2.** Supported. `CUSTOM_S3_ENDPOINT` plus `AWS_REGION` sets the
  signing region, and `USE_PATH_STYLE=true` forces path-style requests
  ([`pkg/s3/s3.go`][s3go]). The README has a Backblaze lifecycle section. Path
  style also means the only hostname contacted is
  `s3.us-west-000.backblazeb2.com`, which keeps the `toFQDNs` rule to a single
  name.
- **Local path / NFS.** **Not supported.** The tool is S3-only: it takes the
  snapshot, checks the trailing sha256 (`size % 512 == 32`), optionally
  compresses and encrypts, then `PutObject`s. It writes temp files relative to
  its working directory, so `workingDir: /tmp` on an emptyDir is required.
- **Talos client.** It uses `talosconfig.Open("")`, which calls
  `os.UserHomeDir()` ([talos `path.go`][path]), so `HOME` must be set in the
  scratch image. `TALOSCONFIG` points at the mounted Talos SA secret. The
  injected talosconfig's endpoint is `talos.default`, a Talos-managed Service
  whose EndpointSlice points at the three node IPs on :50000 (verified live).
- **Age recipients.** `age.ParseRecipients` in age v1.3.1 accepts only X25519
  (`age1…`) and hybrid post-quantum (`age1pq1…`) recipients ([age `parse.go`][agep]).
  **Plugin recipients such as `age1yubikey1…` will fail** because the scratch
  image has no plugin binaries. This decides the key-custody design below.

### Other home-ops repos

- [billimek/k8s-gitops][bk-hr] runs talos-backup via app-template in
  `kube-system` (6-hourly, Garage target, `HOME=/tmp`, `DISABLE_ENCRYPTION`,
  pinned to `v0.1.0-beta.3`). Its topf patch
  ([machine-features.yaml][bk-talos]) allows `os:admin` + `os:etcd:backup` for
  `kube-system` + `system-upgrade`, which is exactly the cross-product problem
  analysed below: `kube-system` can mint `os:admin`. (Also, `ENABLE_COMPRESSION`
  has no effect on beta.3.)
- [ishioni/homelab-ops][ish] uses a raw CronJob in `kube-system` with an ancient
  alpha image.
- The alternative pattern is a CronJob that runs `talosctl etcd snapshot` and
  then a separate age/upload step. It needs a shell image with talosctl, age, and
  an S3 or NFS client. No official image bundles these, so it means a custom
  image or init-container plumbing. Rejected in favour of the single-purpose
  official binary.

### Talos disaster recovery

From the Talos v1.14 [Disaster Recovery guide][dr]:

- `talosctl -n <IP> etcd snapshot db.snapshot` gives a consistent snapshot from
  any healthy member. When quorum is lost, fall back to `talosctl cp
/var/lib/etcd/member/snap/db` and restore it with `--recover-skip-hash-check`.
- Recovery: make sure every control-plane node has etcd in `Preparing`. Wipe
  EPHEMERAL on nodes that are up but broken, or reinstall them **from the same
  secrets and machine config**. Then run `talosctl -n <IP> bootstrap
--recover-from=./db.snapshot` against a single node; the others join.
- Besides the snapshot you also need the machine configuration, or here the
  topf inputs: `talos/topf.yaml`, the patches, and the **secrets bundle**
  `talos/secrets.sops.yaml`. The bundle holds the CAs, bootstrap token, trustd
  info, and `secretboxencryptionsecret`. Kubernetes Secrets inside etcd are
  secretbox-encrypted at rest, so **a snapshot is unreadable without the
  original bundle**.
- RBAC: [`os:etcd:backup`][rbac] grants `/machine.MachineService/EtcdSnapshot`
  only.

## Design decision: namespace and role

### The constraint (verified)

`kubernetesTalosAPIAccess` (legacy field) and `KubeTalosAPIAccessConfig` (the
new document, [reference][apiacc]) each take one flat `allowedRoles` list and
one flat `allowedKubernetesNamespaces` list. The Talos CRD controller checks
them **independently** ([`crd_controller.go` L347-L372][crd]): the namespace must
be in the list, and each requested role must be in the list. There is no
namespace-to-role mapping, so every allowed namespace can mint every allowed
role. Adding a new `etcd-backup` namespace next to `system-upgrade`, with both
`os:admin` and `os:etcd:backup` allowed, would let anyone who can create a
`talos.dev/ServiceAccount` in `etcd-backup` obtain `os:admin`, i.e. root on
every node.

### Options

| Option                                                                                                                                                               | Security effect                                                                                                                                                                                                          | Cost / risk                                                                                                                                                                                                                                                                                                                                          |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **(a) Run in `system-upgrade`, request only `os:etcd:backup`** ✅                                                                                                    | No new principal can reach `os:admin`: `system-upgrade` already can. Adding `os:etcd:backup` to `allowedRoles` gives `system-upgrade` nothing new, because `os:admin` is a superset. Talos itself enforces the boundary. | The backup pod shares a namespace with a node-root credential (`tuppr-talosconfig` Secret). Mitigated: the pod's own cert holds only `os:etcd:backup`, it runs under a dedicated Kubernetes SA with no RBAC and no token, and it is restricted-PSS compliant even though the namespace PSA is `privileged`. The namespace name is a slight misnomer. |
| (b) New `etcd-backup` namespace plus admission guard (Kyverno or a native ValidatingAdmissionPolicy restricting `talos.dev/ServiceAccount.spec.roles` per namespace) | Correct while the guard is present and bound                                                                                                                                                                             | The node-root boundary would depend on a Kubernetes object that Flux can prune, that ordering can leave missing (Talos patch applied before the policy), or that a cluster-admin can delete. Kyverno (#524) is not installed yet. A failure silently widens `os:admin` to a second namespace.                                                        |
| (c) Run off-cluster: TrueNAS cron with `talosctl` and a `talosctl config new --roles os:etcd:backup` cert                                                            | No `kubernetesTalosAPIAccess` change at all. Works even when Kubernetes is down.                                                                                                                                         | A long-lived client cert on the NAS, an unmanaged talosctl binary on an appliance OS (no Renovate), awkward monitoring (no kube-state-metrics), and the backup becomes co-located with the NAS failure domain. Worth keeping as a _complementary_ future option.                                                                                     |

**Chosen: (a).** It is the only option where the Talos API itself enforces
that nothing beyond today's `system-upgrade` can obtain `os:admin`, and the
Talos patch is a one-line diff (`topf apply --dry-run` shows exactly
`+ - os:etcd:backup` on all three nodes, applied without a reboot).

What `os:etcd:backup` exposes, for completeness: a snapshot contains every
Kubernetes object, with Secrets secretbox-encrypted using a key that is _not_ in
etcd. A leaked snapshot is sensitive, but not a node-root or plaintext-Secret
disclosure on its own. That is also why snapshots are age-encrypted before they
leave the pod.

### Network policy

`system-upgrade` sits under the cluster-wide default-deny CCNP floor, and tuppr's
CiliumNetworkPolicy is already namespace-wide. The new
`etcd-backup` CNP selects only the backup pods and is self-contained. Egress
allowed: kube-dns :53 with L7 DNS visibility; Talos apid :50000 via
`host`/`remote-node` entities plus the node IPs `192.168.5.50-52` and the VIP
`192.168.5.254`, mirroring tuppr; and `s3.us-west-000.backblazeb2.com:443` via
`toFQDNs`. No ingress. The pod uses `ndots:1` so the FQDN rule matches (#548).

## Backup target

- **Why not Garage:** Garage is in-cluster, on iSCSI, on the NAS. Its restore
  goes through Volsync, which itself needs a working cluster. That is circular.
- **Why B2 direct (primary):** it is independent of both the cluster and the
  NAS, the two failure domains an etcd restore would be recovering from. It is
  offsite within minutes (RPO 6h rather than the 24h nightly Cloud Sync), and
  the tool supports it natively.
- **Why also the NAS (secondary):** fast, egress-free restores, and still
  available if the internet or B2 is unavailable. talos-backup cannot write to
  NFS, so TrueNAS pulls the bucket back into `tank/backups/etcd` 30 minutes
  after each run (Cloud Sync PULL, SYNC mode, no rclone crypt because objects
  are already age-encrypted). `tank/backups` hourly ZFS snapshots are recursive,
  so the new dataset is covered automatically. SYNC mirrors deletions, but the
  in-cluster key cannot delete anything, and ZFS snapshots keep 24h of history.
- **Size:** etcd is about 83 MB in use and about 220 MB on disk per member.
  After zstd, each object should be tens of MB, so 120 objects over 30 days is a
  few GB (cents per month).

### B2 credentials

- A **new application key**, restricted to `sp3nx0r-homelab-etcd`, with
  capability `writeFiles` only. The pod cannot list, read, or delete old
  backups, so a compromised pod cannot destroy history. Add `listBuckets` only
  if B2 rejects uploads without it.
- Bucket, versioning, and lifecycle are managed by
  `ansible/playbooks/backblaze-configure.yml`. The new
  `current_version_expiration_days` setting writes the B2-required pair of
  rules (`Expiration.Days` plus `ExpiredObjectDeleteMarker`) in one PUT ([B2
  docs][b2lc]). Rule IDs round-trip through B2's S3 API (verified read-only on
  `sp3nx0r-homelab`), so the purge step keeps them.
- The existing backblaze-exporter key is account-wide read-only (verified), so
  it will see the new bucket without changes. The TrueNAS "Backblaze B2" Cloud
  Sync credential must be able to read the new bucket for the PULL mirror.

## Encryption and key custody

- Snapshots are age-encrypted to the **existing SOPS recipient**. A dedicated
  key would add a custody burden without adding isolation: whoever holds
  `age.key` can already decrypt `talos/secrets.sops.yaml`, which contains the
  secretbox key and every CA. A DR session needs `age.key` anyway.
- **Recommended second recipient: an offline X25519 "paper" key**, generated on
  an offline machine and printed (plus stored in the password manager). Add its
  public key to `AGE_RECIPIENT_PUBLIC_KEY` (comma-separated) _and_ to every
  `creation_rule` in `.sops.yaml`, then run `sops updatekeys` on all
  `*.sops.*` files. Losing `age.key` is then no longer fatal.
- A YubiKey (`age-plugin-yubikey`) recipient works for SOPS (plugin support
  since [SOPS v3.10.0][sops-plugins]; the repo pins 3.13.3) but **not** for
  talos-backup (see Research). If you want one, use it for `.sops.yaml` only,
  and keep the paper key as the snapshot's second recipient. Those snapshots
  are useless without `talos/secrets.sops.yaml` anyway, which the YubiKey would
  unlock.
- The full root-secret inventory and custody plan is in the
  [DR runbook](backup-and-recovery/runbook-disaster-recovery.md#root-secrets-and-offline-custody).

## Monitoring

| Alert                                             | Expression (abridged)                                                                                   | For | Severity |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | --- | -------- |
| `EtcdBackupStale`                                 | `time() - kube_cronjob_status_last_successful_time{cronjob="etcd-backup"} > 12h`                        | 15m | warning  |
| `EtcdBackupNeverSucceeded`                        | `absent(kube_cronjob_status_last_successful_time{cronjob="etcd-backup"})`                               | 12h | warning  |
| `EtcdBackupOffsiteStale`                          | newest object in `sp3nx0r-homelab-etcd` (`backblaze_b2_path_last_upload_seconds`, in ms) older than 13h | 30m | warning  |
| `KubeJobFailed` (existing, kube-prometheus-stack) | any failed job                                                                                          | 15m | warning  |

`EtcdBackupOffsiteStale` checks end to end, independently of the Job's exit
code. The bucket is also added to `BackblazeExporterBucketMissing`. The
existing `BackblazeBucketNewestObjectStale` (14 days) and
`BackblazeBucketSizeDropped` rules apply automatically. `severity=warning`
routes to Discord through the existing Alertmanager config.

## Files changed

| Path                                                | Change                                                                                                                                                                             |
| --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `kubernetes/apps/system-upgrade/etcd-backup/`       | New app: `ks.yaml`, HelmRelease (app-template CronJob), OCIRepository, Talos `ServiceAccount` (`os:etcd:backup`), CNP, PrometheusRule, SOPS Secret with placeholder B2 credentials |
| `kubernetes/apps/system-upgrade/kustomization.yaml` | Lists `etcd-backup/ks.yaml`                                                                                                                                                        |
| `kubernetes/apps/o11y/backblaze-exporter/app/`      | Scrapes the new bucket; missing-bucket alert                                                                                                                                       |
| `talos/control-plane/00-cluster.yaml`               | `allowedRoles` gains `os:etcd:backup` (namespace list unchanged)                                                                                                                   |
| `ansible/inventory/group_vars/backblaze/vars.yml`   | New bucket `sp3nx0r-homelab-etcd`                                                                                                                                                  |
| `ansible/playbooks/backblaze-configure.yml`         | Optional `current_version_expiration_days` lifecycle rule                                                                                                                          |
| `ansible/inventory/host_vars/hl8/vars.yml`          | Dataset `tank/backups/etcd`; Cloud Sync PULL task                                                                                                                                  |
| `ansible/playbooks/truenas-configure.yml`           | Cloud Sync create payload honours per-task `direction`/`transfer_mode`/`encryption` (defaults unchanged: PUSH/SYNC/crypt)                                                          |

## Validation performed (read-only)

- `kustomize build` for `system-upgrade`, the new app, and backblaze-exporter.
- `helm template` of app-template 5.2.1 with the HelmRelease values, then
  `kubeconform -strict` (8/8 valid, including the `talos.dev` ServiceAccount
  schema).
- `kubectl apply --dry-run=server` on every new object, the rendered
  CronJob/ServiceAccount, and the Flux Kustomization. The
  `serviceaccounts.talos.dev` CRD exists (tuppr's `tuppr-talosconfig` uses it).
- `promtool check rules` on both PrometheusRules.
- `topf apply --dry-run`: one-line diff per node, no reboot.
- `ansible-playbook --syntax-check` and `ansible-lint` (production profile).
  Rendered the new Cloud Sync payloads for a PUSH task and the PULL task, and
  the lifecycle script for buckets with and without expiration.
- Checked that the HelmRelease recipient is `age-keygen -y age.key` and that
  zstd→age→decrypt round-trips (dummy data, not a real snapshot).

## Manual steps (in order)

1. **Bucket:** run `just ansible backblaze-dry-run`, then `just ansible backblaze`,
   to create `sp3nx0r-homelab-etcd` with versioning and lifecycle. Confirm in the B2
   console that the rules show _hide after 30 days, delete 1 day after hiding,
   cancel unfinished large files after 7 days_.
2. **Write-only key:**
   `b2 key create --bucket sp3nx0r-homelab-etcd talos-etcd-backup writeFiles`.
   Put the key ID and key into
   `kubernetes/apps/system-upgrade/etcd-backup/app/secret.sops.yaml` with
   `sops` and commit to this branch.
3. **(Recommended) Offline recipient:** generate the paper key offline and
   append its public key to `AGE_RECIPIENT_PUBLIC_KEY` (and `.sops.yaml` plus
   `sops updatekeys`, as a separate PR).
4. **Talos:** `just talos diff`, then `just talos apply`. Expect the one-line
   `allowedRoles` change, applied without a reboot.
5. **Merge** the PR. Flux creates the Talos SA. Check that
   `kubectl -n system-upgrade get serviceaccounts.talos.dev etcd-backup-talos -o yaml`
   has no error status and that the `etcd-backup-talos` Secret exists.
6. **First run:**
   `kubectl -n system-upgrade create job --from=cronjob/etcd-backup etcd-backup-manual`,
   then check the logs and that an object appears in B2. Delete the manual job
   afterwards.
7. **NAS mirror:** `just ansible nas --tags datasets,cloudsync` creates
   `tank/backups/etcd` and the PULL task. Confirm the TrueNAS B2 credential can
   read the new bucket, run the task once from the UI, and check the files.
8. **Drill** (below) within the first week.

## Restore drill proposal

- **Monthly (safe, workstation only), about 5 minutes:** download the newest
  object (from the NAS mirror or B2), `age -d -i age.key | zstd -d`, then
  `etcdutl snapshot status -w table`. Check that the revision is close to the
  live one (`talosctl etcd status`) and that the key count is similar to the
  previous drill. This proves
  the object is complete and decryptable with the offline key. Also decrypt one
  object with the **paper key** once a year.
- **Annually (optional), isolated full restore:** `talosctl cluster create`
  (Docker provisioner) using the _production secrets bundle_, then
  `talosctl bootstrap --recover-from`. This must run on a host with **no
  outbound network**. Otherwise restored controllers (cloudflared, external-dns,
  Flux, Volsync) would act on real Cloudflare, DNS, Git, and NAS resources.
  Because of that risk, a real-hardware drill of the documented procedure is
  better done during a planned maintenance window instead.
- Record each drill (date, object, result) at the bottom of
  `runbook-restore-etcd.md`.

## Open questions

1. **Namespace naming.** `system-upgrade` now means "Talos-API trust zone".
   Rename it later (e.g. `talos-system`)? That touches tuppr and the Talos
   patch, so it's out of scope here.
2. **Renovate.** The pinned tag is an untagged `main` build
   (`v0.1.0-beta.3-10-g…`), so Renovate's docker versioning will not propose
   updates. Watch upstream for a `v0.1.0` release, or add a regex-versioning
   packageRule?
3. **Object Lock.** Enable B2 Object Lock (governance, about 7 days) on the new
   bucket for ransomware resistance against the account-wide Ansible key? It
   must be chosen at bucket creation and isn't supported by the current
   `amazon.aws.s3_bucket` usage.
4. **Ansible B2 key scope.** The Ansible B2 key is account-wide with
   `writeKeys`/`deleteBuckets`/`bypassGovernance` (verified). It is effectively
   a master key in a SOPS file. Split it into a lifecycle-only key and keep
   key-management in the console?
5. **Complementary off-cluster snapshot** (option c) for the "Kubernetes is
   down but etcd is healthy" case? Today you would run `talosctl etcd snapshot`
   by hand from the workstation, which is covered in the runbook.

[tb]: https://github.com/siderolabs/talos-backup
[0b3984d]: https://github.com/siderolabs/talos-backup/commit/0b3984d3f218d5717978054c70eb5efb0c52c3e3
[3022fec]: https://github.com/siderolabs/talos-backup/commit/3022fec
[38dad7c]: https://github.com/siderolabs/talos-backup/commit/38dad7c
[6f0422e]: https://github.com/siderolabs/talos-backup/commit/6f0422e6e021260041bc2ac88340cff93288516c
[b9fd478]: https://github.com/siderolabs/talos-backup/commit/b9fd478c333045e173ad6d311102ee471e0b15b3
[svc]: https://github.com/siderolabs/talos-backup/blob/b9fd478c333045e173ad6d311102ee471e0b15b3/pkg/config/service.go
[s3go]: https://github.com/siderolabs/talos-backup/blob/b9fd478c333045e173ad6d311102ee471e0b15b3/pkg/s3/s3.go
[path]: https://github.com/siderolabs/talos/blob/76e761d83f7f894021613c6041aa77b21632851a/pkg/machinery/client/config/path.go
[crd]: https://github.com/siderolabs/talos/blob/76e761d83f7f894021613c6041aa77b21632851a/internal/app/machined/pkg/controllers/kubeaccess/serviceaccount/crd_controller.go#L347-L372
[agep]: https://github.com/FiloSottile/age/blob/v1.3.1/parse.go#L103-L112
[bk-hr]: https://github.com/billimek/k8s-gitops/blob/main/kubernetes/kube-system/etcd/etcd-backup/etcd-backup.yaml
[bk-talos]: https://github.com/billimek/k8s-gitops/blob/main/setup/talos/topf-patches/control-plane/machine-features.yaml
[ish]: https://github.com/ishioni/homelab-ops/blob/main/kubernetes/apps/kube-system/talos-backup/app/cronjob.yaml
[dr]: https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery
[rbac]: https://docs.siderolabs.com/talos/v1.14/security/rbac
[apiacc]: https://docs.siderolabs.com/talos/v1.14/reference/configuration/kubernetes/kubetalosapiaccessconfig
[b2lc]: https://www.backblaze.com/apidocs/s3-put-lifecycle-configuration
[sops-plugins]: https://github.com/getsops/sops/releases/tag/v3.10.0
