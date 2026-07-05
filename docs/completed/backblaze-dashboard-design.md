# Backblaze Capacity Dashboard and Alerts Design

## Goal

Add observability for Backblaze B2 backup capacity, freshness, and destructive
drop detection. The dashboard should answer whether the expected buckets are in
use, how storage is changing, and whether any bucket appears stale or suddenly
reduced. Alerts should catch the same failure modes without requiring someone to
watch Grafana.

## Scope

- Add one Grafana dashboard JSON for the existing Backblaze exporter metrics.
- Provision the dashboard through the existing Grafana ConfigMap sidecar pattern.
- Add PrometheusRule alerts for exporter health, missing buckets, freshness, and
  unusually large downward bucket changes.
- Keep the implementation limited to the six currently configured B2 buckets:
  `sp3nx0r-backups-archive`, `sp3nx0r-backups-truenas-config`,
  `sp3nx0r-backups-workstation`, `sp3nx0r-homelab`,
  `sp3nx0r-homelab-kopia`, and `sp3nx0r-media`.

## Dashboard Design

Create a local dashboard file at
`kubernetes/apps/o11y/grafana/app/dashboards/backblaze-b2-capacity.json`.
Provision it with a new ConfigMap generator entry in the Grafana app
Kustomization. Put it in a `Backups` Grafana folder with the existing
`grafana_folder` annotation pattern.

The dashboard uses the existing `Prometheus` datasource variable pattern from
the Ollama dashboard.

### Top Row

- Scrape health: current `backblaze_b2_scrape_success` state.
- Buckets present: count of current bucket series compared to the expected six.
- Total B2 bytes: sum of `backblaze_b2_path_size_bytes`.
- Largest 24h drop: most negative bucket-level byte delta over the last day.
  This falls back to `0` until at least 24 hours of metric history exists.
- Stalest B2 object: maximum age from `backblaze_b2_path_last_upload_seconds`.
  This indicates the newest object currently visible in B2, not the last time a
  TrueNAS Cloud Sync job ran.

### Capacity and Growth

- Bucket size over time, split by bucket.
- Total size over time.
- Current size by bucket, sorted descending by current size.
- Current file count by bucket, sorted descending by current file count.
- Bucket display labels drop the `sp3nx0r-` prefix for readability.

### Drop and Freshness Investigation

- 24h byte delta by bucket, emphasizing negative values and falling back to `0`
  until at least 24 hours of metric history exists.
- 24h file-count delta by bucket, emphasizing negative values and falling back to
  `0` until at least 24 hours of metric history exists.
- Newest B2 object age by bucket.
- Inventory table with bucket, scrape success, bytes, files, newest B2 object
  age, 24h byte delta, and 24h file-count delta.

The newest B2 object age is a B2 inventory freshness signal only. A TrueNAS Cloud
Sync job can run successfully without uploading a newer object, so this dashboard
does not prove whether the NAS-side job ran overnight.

### Exporter Health

- Scrape duration by bucket.
- Last successful scrape timestamp or age by bucket.

## Alert Design

Add a `PrometheusRule` in the Backblaze exporter app and include it in that
app's Kustomization.

Alerts:

- `BackblazeExporterBucketScrapeFailed`: a bucket reports
  `backblaze_b2_scrape_success == 0` for a sustained period.
- `BackblazeExporterBucketMissing`: one of the six expected buckets has no
  `backblaze_b2_scrape_success` series for a sustained period.
- `BackblazeBucketNewestObjectStale`: a bucket's newest B2 object age is older
  than 14 days for a sustained period.
- `BackblazeBucketSizeDropped`: a bucket's 24h size delta is sharply negative.
- `BackblazeBucketFileCountDropped`: a bucket's 24h file-count delta is sharply
  negative.

Initial thresholds must be conservative to avoid noise:

- Missing bucket and scrape failure alert as high severity.
- Freshness alert is warning severity when newest B2 object age exceeds 14 days
  for 1 hour.
- Dashboard freshness thresholds are yellow after 7 days and red after 14 days.
- Size-drop alerts warn on drops greater than 10 percent and 10 MiB, and become
  critical on drops greater than 25 percent and 100 MiB.
- File-count drop alerts warn on drops greater than 10 percent and 10 files, and
  become critical on drops greater than 25 percent and 100 files.

## Validation

- Validate the Grafana app Kustomization builds.
- Validate the Backblaze exporter app Kustomization builds.
- Run kubeconform against generated non-secret manifests using the repo's
  existing CRD schema location pattern.
- Parse dashboard PromQL and PrometheusRule PromQL against the local Prometheus
  API.
- Apply the generated Grafana dashboard ConfigMap locally without committing, so
  the dashboard can be previewed before GitOps rollout.
- After deployment, query the local Prometheus API to confirm the dashboard metric
  names exist for all six buckets.
- Confirm all Flux Kustomizations and HelmReleases are ready after deployment.

## Out of Scope

- Creating a standalone Thanos deployment or changing Grafana datasources.
- Changing Backblaze bucket configuration or cloud sync schedules.
- Confirming NAS-side TrueNAS Cloud Sync job run status.
- Adding automated restore checks.
