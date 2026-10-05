set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']
set default-list
set default-script

# Sigma -> Loki ruler detections. Tool versions (pySigma, backend) are pinned in
# the script's inline metadata and run through uv; see
# docs/loki-ruler-detections.md.

script := justfile_directory() / 'scripts/sigma-to-loki.py'

[doc('Re-fetch the SigmaHQ rules listed in sigma/config.yaml at the pinned ref')]
[group('sigma')]
vendor:
    {{ script }} vendor

[doc('Regenerate the Loki rule groups from sigma/, then lint them')]
[group('sigma')]
generate: && lint
    {{ script }} generate

[doc('Fail if the generated Loki rule groups are stale')]
[group('sigma')]
check:
    {{ script }} check

[doc('Offline LogQL/label lint of every Loki rule group in kubernetes/ [paths=optional]')]
[group('sigma')]
[no-cd]
lint *paths:
    {{ script }} lint {{ paths }}

[doc('Run every rule against the live Loki and report 7d firing windows [files=optional]')]
[group('sigma')]
[no-cd]
validate *files:
    kubectl --namespace o11y port-forward pod/loki-0 3100:3100 >/dev/null &
    trap 'kill %1' EXIT
    until curl --silent --fail http://localhost:3100/ready >/dev/null; do sleep 1; done
    {{ script }} validate --loki-url http://localhost:3100 {{ files }}
