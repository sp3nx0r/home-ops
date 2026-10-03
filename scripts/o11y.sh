# shellcheck shell=bash
# Read-only query helpers for the in-cluster o11y stack via the kube-apiserver
# service proxy (no port-forwards). Source from inside the repo so mise sets
# KUBECONFIG:  source scripts/o11y.sh
#
#   q   '<promql>' [unix_ts]          instant query, local Prometheus (retention 7d / 5GB)
#   qr  '<promql>' [minutes] [step_s] range query, Prometheus, prints time=value series
#   tq  '<promql>' [unix_ts]          instant query, Thanos Query (90d at 1h, partial_response=false)
#   tqr '<promql>' [hours] [step_s]   range query, Thanos Query Frontend (splits per 24h)
#   lq  '<logql metric query>'        instant LogQL metric query, Loki
#   lqr '<logql>' [minutes] [limit]   raw log lines (JSON per line) from Loki, oldest first
#   am                                active Alertmanager alerts (name, state, labels)
#
#   o11y_cli_env                      export settings so logcli/promtool/amtool use the same proxy:
#     logcli query --since=6h --limit=20000 --batch=5000 -o raw '{namespace="media"}'
#     promtool query instant --http.config.file="$O11Y_HTTP_CONFIG" "$THANOS_URL" '<promql>'
#     amtool --alertmanager.url="$ALERTMANAGER_URL" --http.config.file="$O11Y_HTTP_CONFIG" alert query
#   o11y_cli_clean                    remove the extracted client cert and unset the variables

_o11y_svc=/api/v1/namespaces/o11y/services
_o11y_enc() { jq -rn --arg q "$1" '$q|@uri'; }

q() {
  kubectl get --raw "$_o11y_svc/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(_o11y_enc "$1")${2:+&time=$2}" |
    jq -c '(.error // empty), (.data.result[]? | {m: .metric, v: .value[1]})'
}

qr() {
  local mins=${2:-60} step=${3:-60} end
  end=$(date +%s)
  kubectl get --raw "$_o11y_svc/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query_range?query=$(_o11y_enc "$1")&start=$((end - mins * 60))&end=$end&step=$step" |
    jq -r '(.error // empty), (.data.result[]? | (.metric | tostring) + "  " + ([.values[] | "\(.[0] | strftime("%m-%dT%H:%M"))=\(.[1])"] | join(" ")))'
}

tq() {
  kubectl get --raw "$_o11y_svc/thanos-query:9090/proxy/api/v1/query?query=$(_o11y_enc "$1")&partial_response=false${2:+&time=$2}" |
    jq -c '(.error // empty), (.warnings // empty), (.data.result[]? | {m: .metric, v: .value[1]})'
}

tqr() {
  local hrs=${2:-72} step=${3:-1800} end
  end=$(date +%s)
  kubectl get --raw "$_o11y_svc/thanos-query-frontend:9090/proxy/api/v1/query_range?query=$(_o11y_enc "$1")&start=$((end - hrs * 3600))&end=$end&step=$step&partial_response=false" |
    jq -r '(.error // empty), (.warnings // empty | tostring), (.data.result[]? | (.metric | tostring) + "  " + ([.values[] | "\(.[0] | strftime("%m-%dT%H:%M"))=\(.[1])"] | join(" ")))'
}

lq() {
  kubectl get --raw "$_o11y_svc/loki:3100/proxy/loki/api/v1/query?query=$(_o11y_enc "$1")&time=$(date +%s)" |
    jq -r '(.error // empty), (.data.result[]? | "\(.value[1])\t\(.metric | to_entries | map("\(.key)=\(.value)") | join(" "))")' | sort -rn
}

lqr() {
  local mins=${2:-60} limit=${3:-1000} now
  now=$(date +%s)
  kubectl get --raw "$_o11y_svc/loki:3100/proxy/loki/api/v1/query_range?query=$(_o11y_enc "$1")&start=$((now - mins * 60))000000000&end=${now}000000000&limit=$limit&direction=forward" |
    jq -r '.data.result[]?.values[]?[1]'
}

am() {
  kubectl get --raw "$_o11y_svc/kube-prometheus-stack-alertmanager:9093/proxy/api/v2/alerts?active=true" |
    jq -r '.[] | "\(.labels.alertname)\t\(.status.state)\t\(.labels | del(.alertname, .prometheus) | tostring)"'
}

_o11y_cli_dir="${XDG_RUNTIME_DIR:-$HOME/.cache}/home-ops-o11y"

_o11y_kc() { kubectl config view --minify --raw -o jsonpath="{$1}"; }

# The CLIs can't use a kubeconfig, so the client cert is written (0600, in a
# 0700 dir on tmpfs when XDG_RUNTIME_DIR is set) for them to present to the
# apiserver proxy. It is the same credential the kubeconfig already holds.
o11y_cli_env() {
  local d=$_o11y_cli_dir base
  base="$(_o11y_kc '.clusters[0].cluster.server')$_o11y_svc"
  if [[ -z $(_o11y_kc '.users[0].user.client-certificate-data') ]]; then
    echo "o11y_cli_env: kubeconfig has no embedded client certificate" >&2
    return 1
  fi
  (
    umask 077
    mkdir -p "$d"
    _o11y_kc '.users[0].user.client-certificate-data' | base64 -d >"$d/client.crt"
    _o11y_kc '.users[0].user.client-key-data' | base64 -d >"$d/client.key"
    _o11y_kc '.clusters[0].cluster.certificate-authority-data' | base64 -d >"$d/ca.crt"
    printf 'tls_config:\n  cert_file: %s\n  key_file: %s\n  ca_file: %s\n' \
      "$d/client.crt" "$d/client.key" "$d/ca.crt" >"$d/http.yaml"
  ) || return 1
  export LOKI_ADDR="$base/loki:3100/proxy" \
    LOKI_CLIENT_CERT_PATH="$d/client.crt" LOKI_CLIENT_KEY_PATH="$d/client.key" LOKI_CA_CERT_PATH="$d/ca.crt" \
    PROM_URL="$base/kube-prometheus-stack-prometheus:9090/proxy" \
    THANOS_URL="$base/thanos-query-frontend:9090/proxy" \
    ALERTMANAGER_URL="$base/kube-prometheus-stack-alertmanager:9093/proxy" \
    O11Y_HTTP_CONFIG="$d/http.yaml"
}

o11y_cli_clean() {
  rm -rf "$_o11y_cli_dir"
  unset LOKI_ADDR LOKI_CLIENT_CERT_PATH LOKI_CLIENT_KEY_PATH LOKI_CA_CERT_PATH \
    PROM_URL THANOS_URL ALERTMANAGER_URL O11Y_HTTP_CONFIG
}
