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
