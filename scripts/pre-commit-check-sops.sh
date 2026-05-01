#!/usr/bin/env bash
# Ensure *.sops.y*ml files committed are actually encrypted (Mozilla SOPS).
set -euo pipefail

if ! command -v sops >/dev/null 2>&1; then
  echo "pre-commit (check-sops-encrypted): sops not found in PATH" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "pre-commit (check-sops-encrypted): python3 not found in PATH" >&2
  exit 1
fi

status_encrypted() {
  sops filestatus "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get("encrypted") else 1)'
}

for f in "$@"; do
  [[ -f "$f" ]] || continue
  if ! status_encrypted "$f"; then
    echo "pre-commit (check-sops-encrypted): file is not encrypted (encrypt with sops): $f" >&2
    exit 1
  fi
done
