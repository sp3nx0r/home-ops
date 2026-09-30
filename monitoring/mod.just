set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

# External (outside-the-cluster) monitoring: the healthchecks.io dead man's
# switch fed by the Alertmanager Watchdog, and UptimeRobot outside-in HTTP checks
# of the public endpoints. Both recipes are idempotent and safe to re-run. API
# keys come from the environment and are passed to curl via process
# substitution so they never appear in argv. See docs/alerting-heartbeat-plan.md.

am_secret := justfile_directory() / 'kubernetes/apps/o11y/kube-prometheus-stack/app/secret.sops.yaml'
cluster_secrets := justfile_directory() / 'kubernetes/components/sops/cluster-secrets.sops.yaml'

[doc('Upsert the healthchecks.io Watchdog check and store its ping URL in SOPS [HC_API_KEY=required]')]
[group('monitoring')]
healthchecks timeout='300' grace='300':
    : "${HC_API_KEY:?set HC_API_KEY to a healthchecks.io project read-write API key}"
    body="$(jq -n --argjson timeout {{ timeout }} --argjson grace {{ grace }} '{
        name: "Alertmanager Watchdog",
        slug: "alertmanager-watchdog",
        tags: "home-ops alertmanager",
        desc: "Alertmanager POSTs the always-firing Watchdog alert every ~1m. Missing pings mean Prometheus, Alertmanager, the cluster network or the uplink is down.",
        timeout: $timeout,
        grace: $grace,
        methods: "POST",
        channels: "*",
        unique: ["slug"]
    }')"
    resp="$(curl -fsS -X POST https://healthchecks.io/api/v3/checks/ \
        -H @<(printf 'X-Api-Key: %s\n' "$HC_API_KEY") \
        -H 'Content-Type: application/json' -d "$body")"
    ping_url="$(jq -er .ping_url <<<"$resp")"
    sops set "{{ am_secret }}" '["stringData"]["HEARTBEAT_PING_URL"]' "$(jq -n --arg u "$ping_url" '$u')"
    just log info "healthchecks.io check ready; ping URL written to SOPS (commit it)" \
        status "$(jq -r .status <<<"$resp")" timeout "{{ timeout }}" grace "{{ grace }}" \
        channels "$(jq -r '.channels | split(",") | length' <<<"$resp")"

[doc('Create any missing UptimeRobot outside-in HTTP monitors [UPTIMEROBOT_API_KEY=required]')]
[group('monitoring')]
uptimerobot:
    : "${UPTIMEROBOT_API_KEY:?set UPTIMEROBOT_API_KEY to an UptimeRobot main API key}"
    api() {
        curl -fsS -H @<(printf 'Authorization: Bearer %s\n' "$UPTIMEROBOT_API_KEY") \
            -H 'Content-Type: application/json' "$@"
    }
    domain="$(sops -d --extract '["stringData"]["SECRET_DOMAIN"]' "{{ cluster_secrets }}")"
    # Free plan: threshold/recurrence are always 0 and the API allows 10 req/min.
    contacts="$(api https://api.uptimerobot.com/v3/user/alert-contacts \
        | jq -c '[.[] | {alertContactId: .id, threshold: 0, recurrence: 0}]')"
    while read -r name url; do
        count="$(api -G --data-urlencode "url=$url" https://api.uptimerobot.com/v3/monitors \
            | jq --arg u "$url" '[.data[] | select(.url == $u)] | length')"
        if [[ "$count" -gt 0 ]]; then
            just log info "Monitor exists, skipping" name "$name"
            continue
        fi
        api -X POST https://api.uptimerobot.com/v3/monitors -o /dev/null -d "$(jq -n \
            --arg name "$name" --arg url "$url" --argjson contacts "$contacts" '{
                friendlyName: $name, type: "HTTP", url: $url, interval: 300, timeout: 30,
                httpMethodType: "GET", assignedAlertContacts: $contacts, tagNames: ["home-ops"]
            }')"
        just log info "Monitor created" name "$name" contacts "$(jq length <<<"$contacts")"
        sleep 7
    done <<EOF
    status https://status.$domain/
    echo https://echo.$domain/
    plex https://plex.$domain/identity
    kromgo https://kromgo.$domain/
    EOF
