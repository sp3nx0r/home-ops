#!/usr/bin/env bash
set -euo pipefail

rendered="$(kubectl kustomize kubernetes/apps/default/volsync-test/app)"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

document() {
  printf '%s\n' "$rendered" | awk -v kind="$1" -v name="$2" '
    BEGIN { RS="---" }
    $0 ~ ("(^|\\n)kind: " kind "(\\n|$)") && $0 ~ ("(^|\\n)metadata:\\n  name: " name "(\\n|$)") {
      sub(/^\n/, "")
      print
    }
  '
}

require_pattern() {
  if ! grep -Eq -- "$2" <<<"$1"; then
    fail "missing required field: $3"
  fi
}

role_has_exact_least_privilege() {
  awk '
    function indentation(line) {
      match(line, /[^[:space:]]/)
      return RSTART - 1
    }
    function unquote(value,    quote) {
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      quote = substr(value, 1, 1)
      if ((quote == "\"" || quote == sprintf("%c", 39)) && substr(value, length(value), 1) == quote) value = substr(value, 2, length(value) - 2)
      return value
    }
    function set_field(line,    separator) {
      separator = index(line, ":")
      if (!separator) {
        invalid = 1
        return
      }
      field = substr(line, 1, separator - 1)
      if (field != "apiGroups" && field != "resourceNames" && field != "resources" && field != "verbs") invalid = 1
    }
    function add_value(value) {
      if (field == "") {
        invalid = 1
        return
      }
      value = unquote(value)
      values[rule, field, value] = 1
      counts[rule, field]++
    }
    function has_exact(rule_number, field_name, first, second, expected_count) {
      return counts[rule_number, field_name] == expected_count && values[rule_number, field_name, first] && (!second || values[rule_number, field_name, second])
    }
    function job_rule(rule_number) {
      return has_exact(rule_number, "apiGroups", "batch", "", 1) && has_exact(rule_number, "resourceNames", "volsync-src-volsync-test", "", 1) && has_exact(rule_number, "resources", "jobs", "", 1) && has_exact(rule_number, "verbs", "get", "", 1)
    }
    function pvc_rule(rule_number) {
      return has_exact(rule_number, "apiGroups", "", "", 1) && has_exact(rule_number, "resourceNames", "volsync-src-volsync-test-cache", "", 1) && has_exact(rule_number, "resources", "persistentvolumeclaims", "", 1) && has_exact(rule_number, "verbs", "get", "delete", 2)
    }
    /^[[:space:]]*rules:$/ {
      in_rules = 1
      rules_indentation = indentation($0)
      next
    }
    in_rules {
      if ($0 ~ /^[[:space:]]*$/) next
      line_indentation = indentation($0)
      if (line_indentation < rules_indentation || (line_indentation == rules_indentation && $0 !~ /^[[:space:]]*-[[:space:]]/)) exit
      if (line_indentation == rules_indentation && $0 ~ /^[[:space:]]*-[[:space:]]/) {
        rule++
        field = ""
        sub(/^[[:space:]]*-[[:space:]]*/, "", $0)
        set_field($0)
        next
      }
      sub(/^[[:space:]]*/, "", $0)
      if ($0 ~ /^-[[:space:]]/) {
        sub(/^-[[:space:]]*/, "", $0)
        add_value($0)
      } else {
        set_field($0)
      }
    }
    END { exit !(in_rules && !invalid && rule == 2 && ((job_rule(1) && pvc_rule(2)) || (job_rule(2) && pvc_rule(1)))) }
  ' <<<"$1"
}

role_binding_is_exact() {
  awk '
    function indentation(line) {
      match(line, /[^[:space:]]/)
      return RSTART - 1
    }
    function unquote(value,    quote) {
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      quote = substr(value, 1, 1)
      if ((quote == "\"" || quote == sprintf("%c", 39)) && substr(value, length(value), 1) == quote) value = substr(value, 2, length(value) - 2)
      return value
    }
    function flush_subject() {
      if (!subject_started) return
      subject_count++
      if (subject_kind != "ServiceAccount" || subject_name != "volsync-test-cache-scrub" || (subject_namespace != "" && subject_namespace != "default")) invalid = 1
      subject_started = 0
      subject_kind = ""
      subject_name = ""
      subject_namespace = ""
    }
    /^[[:space:]]*roleRef:$/ {
      in_role_ref = 1
      role_ref_indentation = indentation($0)
      next
    }
    in_role_ref {
      if ($0 ~ /^[[:space:]]*$/) next
      line_indentation = indentation($0)
      if (line_indentation <= role_ref_indentation) {
        in_role_ref = 0
      } else {
        sub(/^[[:space:]]*/, "", $0)
        separator = index($0, ":")
        if (!separator) {
          invalid = 1
          next
        }
        key = substr($0, 1, separator - 1)
        value = unquote(substr($0, separator + 1))
        if (key != "apiGroup" && key != "kind" && key != "name") invalid = 1
        role_ref_count[key]++
        role_ref_value[key] = value
        next
      }
    }
    /^[[:space:]]*subjects:$/ {
      in_subjects = 1
      subjects_indentation = indentation($0)
      next
    }
    in_subjects {
      if ($0 ~ /^[[:space:]]*$/) next
      line_indentation = indentation($0)
      if (line_indentation < subjects_indentation || (line_indentation == subjects_indentation && $0 !~ /^[[:space:]]*-[[:space:]]/)) {
        flush_subject()
        in_subjects = 0
        next
      }
      if (line_indentation == subjects_indentation && $0 ~ /^[[:space:]]*-[[:space:]]/) {
        flush_subject()
        subject_started = 1
        sub(/^[[:space:]]*-[[:space:]]*/, "", $0)
      } else if (!subject_started) {
        invalid = 1
        next
      } else {
        sub(/^[[:space:]]*/, "", $0)
      }
      separator = index($0, ":")
      if (!separator) {
        invalid = 1
        next
      }
      key = substr($0, 1, separator - 1)
      value = unquote(substr($0, separator + 1))
      if (key == "kind") subject_kind = value
      else if (key == "name") subject_name = value
      else if (key == "namespace") subject_namespace = value
      else invalid = 1
    }
    END {
      flush_subject()
      exit !(in_subjects || subject_count) || invalid || role_ref_count["apiGroup"] != 1 || role_ref_count["kind"] != 1 || role_ref_count["name"] != 1 || role_ref_value["apiGroup"] != "rbac.authorization.k8s.io" || role_ref_value["kind"] != "Role" || role_ref_value["name"] != "volsync-test-cache-scrub" || subject_count != 1
    }
  ' <<<"$1"
}

scrub_container() {
  awk '
    function indentation(line) {
      match(line, /[^[:space:]]/)
      return RSTART - 1
    }
    function flush() {
      if (container == "") return
      container_count++
      if (container ~ /(^|\n)[[:space:]]*-?[[:space:]]*name: scrub([[:space:]]|$)/) {
        scrub_count++
        scrub = container
      }
      container = ""
    }
    /^[[:space:]]*containers:$/ {
      in_containers = 1
      containers_indentation = indentation($0)
      next
    }
    in_containers {
      if ($0 ~ /^[[:space:]]*$/) {
        if (container != "") container = container "\n" $0
        next
      }
      line_indentation = indentation($0)
      if (line_indentation < containers_indentation || (line_indentation == containers_indentation && $0 !~ /^[[:space:]]*-[[:space:]]/)) exit
      if (line_indentation == containers_indentation && $0 ~ /^[[:space:]]*-[[:space:]]/) {
        flush()
        container = $0
        next
      }
      if (container != "") container = container "\n" $0
    }
    END {
      flush()
      if (container_count == 1 && scrub_count == 1) print scrub
    }
  ' <<<"$1"
}

command_lines() {
  awk '
    /^[[:space:]]*command:$/ { printing = 1; next }
    printing && /^[[:space:]]*-[[:space:]]/ {
      sub(/^[[:space:]]*/, "")
      print
      next
    }
    printing { exit }
  ' <<<"$1"
}

args_script() {
  awk '
    function indentation(line) {
      match(line, /[^[:space:]]/)
      return RSTART - 1
    }
    function append(line) {
      script = script == "" ? line : script "\n" line
    }
    BEGIN { script_indentation = -1 }
    /^[[:space:]]*(-[[:space:]]+)?args:$/ { in_args = 1; next }
    in_args && !in_script {
      if ($0 ~ /^[[:space:]]*$/) next
      if ($0 ~ /^[[:space:]]*-[[:space:]]+\|[[:space:]]*$/) {
        block_indentation = indentation($0)
        in_script = 1
        next
      }
      invalid = 1
      exit
    }
    in_script {
      if ($0 ~ /^[[:space:]]*$/) {
        append("")
        next
      }
      line_indentation = indentation($0)
      if (line_indentation <= block_indentation) {
        if (line_indentation == block_indentation && $0 ~ /^[[:space:]]*-[[:space:]]/) invalid = 1
        exit
      }
      if (script_indentation == -1) script_indentation = line_indentation
      if (line_indentation < script_indentation) {
        invalid = 1
        exit
      }
      append(substr($0, script_indentation + 1))
    }
    END { if (in_script && !invalid) print script }
  ' <<<"$1"
}

normalize_script() {
  sed -E "s/jsonpath='\{([^']+)\}'/jsonpath={\1}/g" <<<"$1"
}

cronjob="$(document CronJob volsync-test-cache-scrub)"
role="$(document Role volsync-test-cache-scrub)"
service_account="$(document ServiceAccount volsync-test-cache-scrub)"
role_binding="$(document RoleBinding volsync-test-cache-scrub)"

[[ -n "$cronjob" ]] || fail "missing scrub CronJob"
[[ -n "$role" ]] || fail "missing scrub Role"
[[ -n "$service_account" ]] || fail "missing scrub ServiceAccount"
[[ -n "$role_binding" ]] || fail "missing scrub RoleBinding"

require_pattern "$cronjob" '^[[:space:]]*timeZone:[[:space:]]*America/Chicago[[:space:]]*$' 'timeZone America/Chicago'
require_pattern "$cronjob" '^[[:space:]]*schedule:[[:space:]]*"?30 0 \* \* \*"?[[:space:]]*$' 'schedule 30 0 * * *'
require_pattern "$cronjob" '^[[:space:]]*concurrencyPolicy:[[:space:]]*Forbid[[:space:]]*$' 'concurrencyPolicy Forbid'
require_pattern "$cronjob" '^[[:space:]]*backoffLimit:[[:space:]]*0[[:space:]]*$' 'backoffLimit 0'
require_pattern "$cronjob" '^[[:space:]]*activeDeadlineSeconds:[[:space:]]*300[[:space:]]*$' 'activeDeadlineSeconds 300'
require_pattern "$cronjob" '^[[:space:]]*ttlSecondsAfterFinished:[[:space:]]*86400[[:space:]]*$' 'ttlSecondsAfterFinished 86400'
require_pattern "$cronjob" '^[[:space:]]*serviceAccountName:[[:space:]]*volsync-test-cache-scrub[[:space:]]*$' 'serviceAccountName volsync-test-cache-scrub'
require_pattern "$cronjob" '^[[:space:]]*automountServiceAccountToken:[[:space:]]*true[[:space:]]*$' 'automountServiceAccountToken true'
if grep -Eq '^[[:space:]]*initContainers:$' <<<"$cronjob"; then
  fail "unexpected scrub init container"
fi
scrub="$(scrub_container "$cronjob")"
[[ -n "$scrub" ]] || fail "missing single scrub container"
expected_command=$'- /bin/sh\n- -ec'
[[ "$(command_lines "$scrub")" == "$expected_command" ]] || fail "scrub command must be /bin/sh -ec"
expected_args_script=$'namespace="default"\nmover_job="volsync-src-volsync-test"\ncache_pvc="volsync-src-volsync-test-cache"\n\nmover_active="$(kubectl -n "$namespace" get job "$mover_job" -o jsonpath={.status.active})"\nif [ "${mover_active:-0}" != "0" ]; then\n  echo "VolSync mover is active; skipping cache scrub"\n  exit 0\nfi\n\nkubectl -n "$namespace" delete pvc "$cache_pvc" --ignore-not-found\n\ndeadline=$((SECONDS + 300))\nwhile [ "$SECONDS" -lt "$deadline" ]; do\n  phase="$(kubectl -n "$namespace" get pvc "$cache_pvc" -o jsonpath={.status.phase})"\n  if [ "$phase" = "Bound" ]; then\n    echo "cache PVC is Bound"\n    exit 0\n  fi\n  sleep 5\ndone\n\necho "cache PVC did not become Bound within five minutes" >&2\nexit 1'
[[ "$(normalize_script "$(args_script "$scrub")")" == "$expected_args_script" ]] || fail "scrub args script does not match required control flow"

role_has_exact_least_privilege "$role" || fail "Role rules do not match required least privilege"
role_binding_is_exact "$role_binding" || fail "RoleBinding does not grant the required Role to the scrub ServiceAccount"
scrub_binding_count="$(awk '
  function indentation(line) {
    match(line, /[^[:space:]]/)
    return RSTART - 1
  }
  function grants_scrub_identity(kind, name, namespace) {
    return (kind == "ServiceAccount" && name == "volsync-test-cache-scrub" && (namespace == "" || namespace == "default")) ||
      (kind == "User" && name == "system:serviceaccount:default:volsync-test-cache-scrub") ||
      (kind == "Group" && (name == "system:serviceaccounts:default" || name == "system:serviceaccounts" || name == "system:authenticated"))
  }
  function contains_scrub_identity(document,    lines, line_count, line_number, line, line_indentation, subjects_indentation, in_subjects, subject_started, subject_kind, subject_name, subject_namespace, separator, key, value, quote, found) {
    line_count = split(document, lines, "\n")
    for (line_number = 1; line_number <= line_count; line_number++) {
      line = lines[line_number]
      if (!in_subjects) {
        if (line ~ /^[[:space:]]*subjects:$/) {
          in_subjects = 1
          subjects_indentation = indentation(line)
        }
        continue
      }
      if (line ~ /^[[:space:]]*$/) continue
      line_indentation = indentation(line)
      if (line_indentation < subjects_indentation || (line_indentation == subjects_indentation && line !~ /^[[:space:]]*-[[:space:]]/)) break
      if (line_indentation == subjects_indentation && line ~ /^[[:space:]]*-[[:space:]]/) {
        if (subject_started && grants_scrub_identity(subject_kind, subject_name, subject_namespace)) found = 1
        subject_started = 1
        subject_kind = ""
        subject_name = ""
        subject_namespace = ""
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      } else if (!subject_started) {
        continue
      } else {
        sub(/^[[:space:]]*/, "", line)
      }
      separator = index(line, ":")
      if (!separator) continue
      key = substr(line, 1, separator - 1)
      value = substr(line, separator + 1)
      sub(/^[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      quote = substr(value, 1, 1)
      if ((quote == "\"" || quote == sprintf("%c", 39)) && substr(value, length(value), 1) == quote) value = substr(value, 2, length(value) - 2)
      if (key == "kind") subject_kind = value
      if (key == "name") subject_name = value
      if (key == "namespace") subject_namespace = value
    }
    return found || (subject_started && grants_scrub_identity(subject_kind, subject_name, subject_namespace))
  }
  BEGIN { RS="---" }
  $0 ~ "(^|\\n)kind: (RoleBinding|ClusterRoleBinding)(\\n|$)" && contains_scrub_identity($0) { count++ }
  END { print count + 0 }
' <<<"$rendered")"
[[ "$scrub_binding_count" == 1 ]] || fail "scrub ServiceAccount has unexpected RoleBinding"
