# Runbook: Canarytokens and decoy Secrets

## Alerts

- **CanarySecretAccessed** (critical, Loki ruler): someone read, wrote, or
  tried to read a decoy Secret by name through the Kubernetes API.
- **SecretsBulkListed** (warning, Loki ruler): someone listed Secrets
  cluster-wide or in a decoy namespace without a selector that excludes the
  decoys. The response contained decoy credentials.
- **Canarytoken email or webhook** (from canarytokens.org, outside the
  cluster): a decoy credential was actually _used_ somewhere (AWS API call,
  DNS lookup of the registry hostname, or `kubectl` against the fake cluster).

- **HoneypotTouched** (critical, Loki ruler): something on the LAN connected
  to the OpenCanary honeypot at 192.168.5.27 (see
  [HoneypotTouched](#honeypottouched)).

All of these are high-signal: nothing legitimate reads or uses the decoys.

## What is deployed

Everything lives in `kubernetes/apps/security/shared-credentials/`. The Flux
Kustomization has a deliberately bland name, because Flux stamps it onto every
object as the `kustomize.toolkit.fluxcd.io/name` label and an intruder reading
the decoys would see a name like `canary`. It sets no `targetNamespace`; each
object pins its own namespace.

| Namespace/Secret                 | Key(s)                                              | Canarytoken type | Memo                                                |
| -------------------------------- | --------------------------------------------------- | ---------------- | --------------------------------------------------- |
| `default/aws-backup-credentials` | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`        | AWS API Key      | `home-ops k8s decoy default/aws-backup-credentials` |
| `o11y/headlamp-admin-kubeconfig` | `kubeconfig`                                        | Kubeconfig       | `home-ops k8s decoy o11y/headlamp-admin-kubeconfig` |
| `media/registry-credentials`     | `.dockerconfigjson` (registry hostname = DNS token) | DNS              | `home-ops k8s decoy media/registry-credentials`     |

The Loki rules ship as ConfigMap `o11y/loki-rules-credential-access` (label
`loki_rule: "true"`, picked up by the Loki chart's rules sidecar, which only
watches `o11y`).

To list the decoys in the cluster:

```bash
kubectl get secret -A -l kustomize.toolkit.fluxcd.io/name=shared-credentials
```

Running that list is itself a `list` with a Flux label selector, so it fires
**SecretsBulkListed**. That is expected.

> **Public repo caveat.** `sp3nx0r/home-ops` is public, so the decoy names and
> the detection rules are visible to anyone who reads it. The decoys still
> catch the realistic threat, which is an opportunistic intruder or malware
> with a stolen kubeconfig or ServiceAccount token that dumps Secrets. They
> will not fool someone who studied this repo first.

## Initial setup: generate and inject the tokens

Do this **on the PR branch before merging**. Until then, the Secrets contain
`REPLACE_WITH_…` placeholders, which would give the game away to anyone who
read them in the cluster.

### 1. Pick the alert destination

canarytokens.org sends alerts to an email address and/or a webhook. It formats
Slack, Discord, and MS Teams webhooks natively.

- Recommended: create a **dedicated** Discord webhook, for example in a
  `#canary` channel (Server Settings → Integrations → Webhooks → New Webhook).
  Do not reuse the Alertmanager webhook in `cluster-secrets`
  (`DISCORD_WEBHOOK_URL`). The canary webhook is handed to a third party
  (Thinkst), so it should be revocable on its own.
- Alternatively, use an email address you actually read.

### 2. Create the tokens at <https://canarytokens.org>

For each row in the table above, select the token type, enter the email and/or
webhook, enter the memo **exactly** as listed, and click _Create my
Canarytoken_. The memo is echoed in every alert, so it must identify the
placement unambiguously. Never put anything sensitive in it.

For each token, save the **Manage this Canarytoken** URL (it contains the
token's auth key) in your password manager as
`canarytoken: <namespace>/<secret>`. You need it to view the history,
disable, or rotate the token.

- **AWS API Key:** note the `aws_access_key_id` and `aws_secret_access_key`.
- **Kubeconfig:** download the file. You may rename the cluster, context, and
  user entries so it matches a Talos admin kubeconfig (cluster `kubernetes`,
  context `admin@kubernetes`, user `admin`). **Do not change** `server`,
  `certificate-authority-data`, `client-certificate-data`, or
  `client-key-data`. Those are what make the token fire.
- **DNS:** note the hostname (`<random>.canarytokens.com`). Any lookup of it,
  or of any subdomain of it, fires the token.

### 3. Inject the values with `sops set`

From the repo root (the age key must be available):

```bash
export SOPS_AGE_KEY_FILE="$PWD/age.key"
cd kubernetes/apps/security/shared-credentials/app

# default/aws-backup-credentials — AWS API Key token
sops set aws-backup-credentials.sops.yaml '["stringData"]["AWS_ACCESS_KEY_ID"]' '"<aws_access_key_id>"'
sops set aws-backup-credentials.sops.yaml '["stringData"]["AWS_SECRET_ACCESS_KEY"]' '"<aws_secret_access_key>"'

# o11y/headlamp-admin-kubeconfig — Kubeconfig token (path to the downloaded file)
sops set headlamp-admin-kubeconfig.sops.yaml '["stringData"]["kubeconfig"]' \
  "$(jq -Rs . < ~/Downloads/<downloaded-kubeconfig>)"

# media/registry-credentials — DNS token as the registry hostname.
# The username and password are invented, but should look like a real pull token.
host='<random>.canarytokens.com'
user='svc-pull'
pass="$(openssl rand -base64 24)"
sops set registry-credentials.sops.yaml '["stringData"][".dockerconfigjson"]' "$(
  jq -cn --arg h "$host" --arg u "$user" --arg p "$pass" \
    '{auths: {($h): {username: $u, password: $p, auth: ("\($u):\($p)" | @base64)}}}' \
  | jq -Rs 'rtrimstr("\n")'
)"
unset pass
```

### 4. Verify, then commit

```bash
# Every value decrypts, nothing is still a placeholder, and the JSON is valid.
for f in *.sops.yaml; do sops -d "$f" | grep -q REPLACE_WITH && echo "PLACEHOLDER LEFT: $f"; done
sops -d registry-credentials.sops.yaml | yq '.stringData[".dockerconfigjson"]' | jq -e .auths >/dev/null && echo dockerconfigjson OK
for f in *.sops.yaml; do sops -d "$f" | kubectl apply --dry-run=server -f -; done

# The files must still be encrypted (the lefthook SOPS check enforces this too).
grep -L 'ENC\[' *.sops.yaml   # must print nothing

git add . && git commit -m "chore(canary): inject canarytoken values"
```

### 5. Smoke-test once, after merge and after the Loki ruler is live

1. **In-cluster detection:**
   `kubectl get secret -n default aws-backup-credentials -o name`. Expect a
   **CanarySecretAccessed** alert in Discord within about 2 minutes. That is
   Vector batching (5s), plus the ruler evaluation interval (1m), plus the
   Alertmanager `group_wait` (30s).
2. **AWS token:**
   `AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… aws sts get-caller-identity`.
   The call fails, and the canarytoken alert arrives 2–30 minutes later (it
   goes through CloudTrail).
3. **DNS token:** `dig +short <random>.canarytokens.com`.
4. **Kubeconfig token:** `kubectl --kubeconfig <file> get pods`. It returns a
   permission error and fires the token.

Each test leaves a history entry on the token's manage page. That is fine,
and it proves that alerting works.

## Triage

### CanarySecretAccessed

1. **Is it you?** A `user=admin` with `source_ip=192.168.5.181` (your
   workstation) and a `kubectl` user agent right after you ran something is
   self-inflicted. The same goes for your Pocket ID identity browsing Secrets
   in Headlamp. Otherwise, treat the principal as compromised.
2. **Pull the full audit events** (Grafana → Explore → Loki). The pod name
   and node are in `user.extra` for ServiceAccount tokens:

    ```logql
    {source="kube-audit"} |~ `aws-backup-credentials|headlamp-admin-kubeconfig|registry-credentials`
      | json | objectRef_resource="secrets"
    ```

3. **Scope what else that principal did** (last 24h). Look for other Secret
   reads, `pods/exec`, RBAC changes, and new workloads:

    ```logql
    {source="kube-audit"} | json | user_username="<user from the alert>"
      | line_format "{{.verb}} {{.objectRef_resource}} {{.objectRef_namespace}}/{{.objectRef_name}} {{.responseStatus_code}}"
    ```

4. **Contain**, based on the principal type:
    - **ServiceAccount:** find the pod from `user.extra`
      (`authentication.kubernetes.io/pod-name`) and delete it. Bound tokens die
      with the pod. Then check the image, the workload's RBAC, and how it was
      compromised (Hubble flows, Tetragon events).
    - **OIDC user (Pocket ID):** disable the user or revoke the session in
      Pocket ID.
    - **`admin` client certificate (Talos kubeconfig):** certificates cannot
      be revoked individually. Rotate the Kubernetes CA with
      `talosctl rotate-ca --talos=false --dry-run=false` (it defaults to a dry
      run), then regenerate and redistribute kubeconfigs. If `talosconfig`
      may also be exposed, drop `--talos=false` so both CAs rotate.
5. **Check the canarytoken manage pages.** If the credential was used from
   outside, you get the source IP, user agent, and (for AWS) the API call.
6. **Rotate the real Secrets** in every namespace the principal could read,
   since the decoys were not the only thing it saw. Then rotate the decoys too
   (see below).

### SecretsBulkListed

Over the 7 days of audit data used to design this rule, every hit was the
operator's own `admin` kubeconfig running `kubectl get secrets` from the
workstation. If the principal, source IP, or user agent is anything else,
follow the CanarySecretAccessed triage: the principal has the decoy contents.

### Canarytoken fired (external alert)

A decoy value left the cluster and was used. This is confirmed exfiltration.
Correlate the time with the audit log to find who read it: search for the
Secret name as above, and widen the search to `list` events. Then follow the
containment steps.

### HoneypotTouched

An OpenCanary honeypot (`kubernetes/apps/security/opencanary/`) listens on
the LAN at **192.168.5.27**: fake SSH on 22 and a fake NAS login page on 80.
Nothing legitimate talks to it, so any SSH connection, SSH login attempt, or
HTTP request fires the critical alert. `externalTrafficPolicy: Local` keeps the
real client IP in `src_host`.

1. Identify the device behind `src_host` (UniFi → Clients, or the DHCP
   leases).
2. Read what it did. Login attempts include the username and password it
   tried:

    ```logql
    {namespace="security", container="app", pod=~"opencanary-.+"} |= `"logtype"`
      | json | logtype >= 2000
    ```

3. A lone HTTP GET from a known device (for example a phone's
   network-discovery scan, or a vulnerability scanner you run) is benign.
   Note it here if it recurs. Credential attempts, or any scanning from a
   server or IoT device, point to a compromised host: isolate it at the switch
   or UniFi, then investigate.

The pod runs as nobody with a read-only rootfs, no ServiceAccount token, and
a CiliumNetworkPolicy that allows ingress only from RFC 1918 sources on the
two ports and no egress beyond DNS. To drop the honeypot, remove
`./opencanary/ks.yaml` from `kubernetes/apps/security/kustomization.yaml`.

## Rotation

Rotate a decoy after it fires, or yearly, so that stale tokens don't pile up:

1. Create a new token (same type, memo suffixed with the date).
2. `sops set` the new value (step 3 above) and commit.
3. After Flux has applied it, disable the old token from its manage URL.

## Adding or renaming a decoy

Keep these in sync, or the detection silently stops covering the decoy:

1. The Secret manifest (encrypted) plus its entry in `app/kustomization.yaml`.
2. In `app/loki-rules.yaml`:
    - `CanarySecretAccessed`: the line-filter regex and the
      `(namespace=… and name=…)` clause.
    - `SecretsBulkListed`: the `namespace=~` list, if it is a new namespace.
3. The table in this runbook.

Do not mount a decoy into a pod. Kubelets `watch` mounted Secrets, and that
would make the critical rule fire constantly.

## Detection design and validation

The audit policy (`talos/control-plane/00-cluster.yaml`) logs `secrets` at
`Metadata` before any system-user drop rule, so every named `get`, `watch`,
`patch`, or `delete` carries `objectRef.name`, including 403/404 responses.
Vector ships the events to Loki with the labels `source="kube-audit"` and
`verb`. The fields used are `user.username`, `objectRef.namespace`,
`objectRef.name`, `responseStatus.code`, `requestURI`, `userAgent`, and
`sourceIPs[0]`.

Validation against live Loki (7 days ending 2026-09-30):

- **Named access to Flux-managed Secrets:** only `kustomize-controller`
  (`get` + `patch` every reconcile) and, for mounted Secrets only, kubelets
  (`watch`). The critical rule allowlists `kustomize-controller` for
  `get|patch|create` only, so a prune (`delete`) also alerts. Using existing
  Secrets as stand-ins, the rule returned only the kubelet watches, as
  expected. With the real decoy names, it returned 0 hits until a test
  `kubectl get` (404), which it caught.
- **Unnamed `list` of Secrets:** about 7,500 per week. Almost all are
  selector-scoped: Helm storage (`labelSelector=name=X,owner=helm`, from both
  helm-controller and the Helm CLI), the Grafana sidecars
  (`grafana_dashboard` / `grafana_datasource`), and the Loki sidecar
  (`loki_rule`). The rest come from `namespace-controller` (namespace
  deletion), which is allowlisted. The rule
  ignores a list only when its selector _positively requires_ one of those
  keys, which the decoys never carry. Negated forms (`!=`, `notin`, `!key`)
  still alert. That makes the exclusion principal-agnostic but unable to hide
  a list that returns decoys. Remaining hits: 3 unfiltered `kubectl get
secrets` calls from the operator's `admin` kubeconfig (`media` ×2,
  cluster-wide ×1). That is roughly 3 warnings a week, all self-inflicted.
  This was kept rather than allowlisting `admin`, because a stolen admin
  kubeconfig is the main threat.
- **Informer `watch` calls** on Secrets cluster-wide (reloader,
  cert-manager, Flux, Cilium, and so on) are not alerted. Informers
  list-then-watch from a `resourceVersion`, so the watch replays no existing
  objects. A manual `kubectl get secrets -w` starts with a `list` and is
  caught.

### Known gaps

- **Depends on the Loki ruler** (enabled in a separate PR) and on the Vector
  audit pipeline. If audit shipping stops, these detections go blind.
- **In-cluster phone-home is limited by the default-deny egress floor.** A
  pod that uses the kubeconfig token cannot reach the canary server over
  HTTPS, and nor can the AWS SDK. DNS lookups still resolve through kube-dns,
  so the DNS token fires from inside the cluster. In-cluster reads are
  covered by the audit rule regardless.
- **The public repo** exposes the decoy names (see above).
