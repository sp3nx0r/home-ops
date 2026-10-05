#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.12"
# dependencies = [
#   "pysigma==1.5.1",
#   "pysigma-backend-loki==0.14.0",
#   "pyyaml==6.0.3",
# ]
# ///
"""Convert the Sigma rules under sigma/ into Loki ruler alert groups.

Subcommands (run from the repo root, or via `just sigma <recipe>`):
  vendor    fetch the upstream SigmaHQ rules listed in sigma/config.yaml at the
            pinned commit into sigma/vendor/sigmahq/
  generate  write the Loki rule group files listed in sigma/config.yaml
  check     exit non-zero if a generated file is stale
  lint      offline: parse every Loki rule group in the repo (generated files and
            loki_rule ConfigMaps) with logcli and check its labels
  validate  run every Loki rule against a live Loki and report how many
            evaluation windows would have fired over a lookback period
"""

from __future__ import annotations

import argparse
import difflib
import json
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

import yaml
from sigma.backends.loki import LogQLBackend
from sigma.collection import SigmaCollection
from sigma.processing.pipeline import ProcessingPipeline
from sigma.rule import SigmaLevel, SigmaRule

ROOT = Path(__file__).resolve().parent.parent
SIGMA_DIR = ROOT / "sigma"
CONFIG = SIGMA_DIR / "config.yaml"
VENDOR_DIR = SIGMA_DIR / "vendor" / "sigmahq"

# Sigma level -> Alertmanager severity. `info` is not routed to Discord.
LEVEL_TO_SEVERITY = {
    SigmaLevel.INFORMATIONAL: "info",
    SigmaLevel.LOW: "info",
    SigmaLevel.MEDIUM: "warning",
    SigmaLevel.HIGH: "critical",
    SigmaLevel.CRITICAL: "critical",
}


class _Dumper(yaml.SafeDumper):
    """Emit multi-line strings as block scalars and indent lists under keys."""

    def increase_indent(self, flow: bool = False, indentless: bool = False) -> Any:
        return super().increase_indent(flow, False)


def _str_presenter(dumper: yaml.SafeDumper, data: str) -> yaml.ScalarNode:
    if "\n" in data:
        return dumper.represent_scalar("tag:yaml.org,2002:str", data, style="|")
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


_Dumper.add_representer(str, _str_presenter)


def load_config() -> dict[str, Any]:
    return yaml.safe_load(CONFIG.read_text())


def alert_name(title: str) -> str:
    words = re.findall(r"[A-Za-z0-9]+", title)
    return "".join(w[:1].upper() + w[1:] for w in words)


def cmd_vendor(cfg: dict[str, Any]) -> int:
    upstream = cfg["sigmahq"]
    base = f"https://raw.githubusercontent.com/{upstream['repo']}/{upstream['ref']}"
    for path in upstream["rules"]:
        dest = VENDOR_DIR / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(f"{base}/{path}", timeout=30) as resp:
            body = resp.read().decode()
        header = f"# Vendored from {upstream['repo']}@{upstream['ref']}:{path}\n"
        dest.write_text(oxfmt(header + body, str(dest.relative_to(ROOT))))
        print(f"vendored {path}")
    return 0


def load_collection(cfg: dict[str, Any]) -> SigmaCollection:
    paths = [VENDOR_DIR / p for p in cfg["sigmahq"]["rules"]]
    paths += sorted((SIGMA_DIR / "rules").rglob("*.yml"))
    paths += sorted((SIGMA_DIR / "filters").rglob("*.yml"))
    missing = [p for p in paths if not p.exists()]
    if missing:
        raise SystemExit(f"missing Sigma files (run `vendor`?): {missing}")
    collection = SigmaCollection.load_ruleset(paths)
    collection.resolve_rule_references()
    return collection


def build_rule(
    rule: SigmaRule, query: str, settings: dict[str, Any], output: dict[str, Any], cfg: dict[str, Any]
) -> dict[str, Any]:
    renames: dict[str, str] = output["label_renames"]
    group_by: list[str] = settings.get("group_by", output["group_by"])
    window: str = settings.get("window", output["window"])
    threshold: int = settings.get("threshold", 0)

    stages = [f"{dst}={renames[dst]}" for dst in group_by if dst in renames]
    pipeline = f" | label_format {', '.join(stages)}" if stages else ""
    expr = f"sum by ({', '.join(group_by)}) (\n  count_over_time({query}{pipeline} [{window}])\n) > {threshold}\n"

    severity = settings.get("severity") or LEVEL_TO_SEVERITY[rule.level or SigmaLevel.MEDIUM]
    labels = {"severity": severity, **output["labels"], "sigma_id": str(rule.id)}

    source = rule.source.path if rule.source else None
    rel = Path(source).resolve().relative_to(ROOT) if source else None
    if rel and rel.is_relative_to(VENDOR_DIR.relative_to(ROOT)):
        upstream = cfg["sigmahq"]
        path = rel.relative_to(VENDOR_DIR.relative_to(ROOT))
        rule_url = f"https://github.com/{upstream['repo']}/blob/{upstream['ref']}/{path}"
    else:
        rule_url = f"{output['repo_url']}/{rel}"

    annotations = {
        "summary": settings.get("summary", output["summary"]),
        "description": " ".join((rule.description or rule.title).split()),
        "sigma_rule": rule_url,
        "runbook_url": output["runbook_url"],
    }
    alert: dict[str, Any] = {"alert": settings.get("alert", alert_name(rule.title)), "expr": expr}
    if settings.get("for"):
        alert["for"] = settings["for"]
    alert["labels"] = labels
    alert["annotations"] = annotations
    return alert


def render(cfg: dict[str, Any]) -> dict[Path, str]:
    pipeline = ProcessingPipeline.from_yaml((SIGMA_DIR / cfg["pipeline"]).read_text())
    backend = LogQLBackend(processing_pipeline=pipeline, case_sensitive=True)
    collection = load_collection(cfg)
    rules_by_id = {str(r.id): r for r in collection.rules if isinstance(r, SigmaRule)}

    outputs: dict[Path, str] = {}
    for out in cfg["outputs"]:
        alerts = []
        for rule_id, settings in out["rules"].items():
            settings = settings or {}
            if rule_id not in rules_by_id:
                raise SystemExit(f"{out['file']}: unknown Sigma rule id {rule_id}")
            rule = rules_by_id[rule_id]
            queries = backend.convert_rule(rule)
            if len(queries) != 1:
                raise SystemExit(f"{rule.title}: expected 1 LogQL query, got {len(queries)}")
            alerts.append(build_rule(rule, queries[0], settings, out, cfg))
        doc = {"groups": [{"name": out["group"], "interval": out["interval"], "rules": alerts}]}
        header = (
            "---\n"
            "# Generated by scripts/sigma-to-loki.py from sigma/ -- do not edit by hand.\n"
            "# Regenerate with `just sigma generate`; see docs/loki-ruler-detections.md.\n"
        )
        body = yaml.dump(doc, Dumper=_Dumper, sort_keys=False, width=100, allow_unicode=True)
        outputs[ROOT / out["file"]] = oxfmt(header + body, out["file"])
    return outputs


def oxfmt(content: str, path: str) -> str:
    """Format like the lefthook pre-commit hook does, so `check` stays stable."""
    if not shutil.which("oxfmt"):
        raise SystemExit("oxfmt not found; run through mise (`just sigma ...`)")
    result = subprocess.run(
        ["oxfmt", f"--stdin-filepath={path}"], input=content, capture_output=True, text=True, cwd=ROOT
    )
    if result.returncode != 0:
        raise SystemExit(f"oxfmt failed for {path}: {result.stderr}")
    return result.stdout


def cmd_generate(cfg: dict[str, Any], check: bool) -> int:
    stale = False
    for path, content in render(cfg).items():
        current = path.read_text() if path.exists() else ""
        if current == content:
            continue
        if check:
            stale = True
            sys.stdout.writelines(
                difflib.unified_diff(
                    current.splitlines(True), content.splitlines(True), str(path), "generated"
                )
            )
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
            print(f"wrote {path.relative_to(ROOT)}")
    if stale:
        print("generated Loki rules are stale; run `just sigma generate`", file=sys.stderr)
        return 1
    return 0


def find_rule_groups(paths: list[Path]) -> list[tuple[str, dict[str, Any]]]:
    """Rule-group documents: bare rule files that a configMapGenerator reads
    (rules/*.yaml) and inline data of ConfigMaps labeled loki_rule="true"."""
    found = []
    files = [p for base in paths for p in ([base] if base.is_file() else sorted(base.rglob("*.yaml")))]
    for file in files:
        if file.name.endswith(".sops.yaml"):
            continue
        try:
            docs = list(yaml.safe_load_all(file.read_text()))
        except yaml.YAMLError:
            continue
        for doc in docs:
            if not isinstance(doc, dict):
                continue
            if file.parent.name == "rules" and "groups" in doc:
                found.append((str(file.relative_to(ROOT)), doc))
            labels = (doc.get("metadata") or {}).get("labels") or {}
            if doc.get("kind") == "ConfigMap" and "loki_rule" in labels:
                for key, value in (doc.get("data") or {}).items():
                    name = f"{file.relative_to(ROOT)}[{doc['metadata'].get('name')}/{key}]"
                    found.append((name, yaml.safe_load(value)))
    return found


def cmd_lint(paths: list[Path]) -> int:
    """Offline checks: LogQL parses (via logcli), severity is routable, and the
    structure is a valid rule-group file."""
    if not shutil.which("logcli"):
        raise SystemExit("logcli not found; run through mise (`just sigma lint`)")
    errors = []
    groups = find_rule_groups(paths)
    for source, doc in groups:
        if not isinstance(doc, dict) or not isinstance(doc.get("groups"), list):
            errors.append(f"{source}: not a rule-group file (missing top-level `groups:` list)")
            continue
        names = [g.get("name") for g in doc["groups"]]
        if len(names) != len(set(names)):
            errors.append(f"{source}: duplicate group names {names}")
        for group in doc["groups"]:
            for rule in group.get("rules", []):
                name = rule.get("alert") or rule.get("record") or "<unnamed>"
                where = f"{source}: {group.get('name')}/{name}"
                if not rule.get("expr"):
                    errors.append(f"{where}: missing expr")
                    continue
                if "alert" in rule and rule.get("labels", {}).get("severity") not in ("critical", "warning", "info"):
                    errors.append(f"{where}: labels.severity must be critical, warning, or info")
                # logcli parses the query before --stdin rejects metric queries,
                # so a parse error is the only failure that matters here.
                result = subprocess.run(
                    ["logcli", "query", "--stdin", "--quiet", rule["expr"]],
                    input="",
                    capture_output=True,
                    text=True,
                )
                if "parse error" in result.stderr:
                    errors.append(f"{where}: {result.stderr.strip()}")
    for err in errors:
        print(err, file=sys.stderr)
    print(f"linted {len(groups)} rule file(s): {len(errors)} error(s)")
    return 1 if errors else 0


def _loki_get(url: str, path: str, params: dict[str, str]) -> dict[str, Any]:
    req = f"{url.rstrip('/')}{path}?{urllib.parse.urlencode(params)}"
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:
        return {"status": "error", "error": err.read().decode().strip()}


def cmd_validate(files: list[Path], loki_url: str, days: int, step: str) -> int:
    import time

    failures = 0
    end = int(time.time())
    rows = []
    for file in files:
        doc = yaml.safe_load(file.read_text())
        for group in doc.get("groups", []):
            for rule in group.get("rules", []):
                name = rule.get("alert") or rule.get("record")
                parsed = _loki_get(loki_url, "/loki/api/v1/query", {"query": rule["expr"]})
                if parsed.get("status") != "success":
                    failures += 1
                    severity = rule.get("labels", {}).get("severity", "-")
                    rows.append((name, severity, "PARSE ERROR", parsed.get("error", parsed)))
                    continue
                buckets = 0
                series: set[str] = set()
                for day in range(days):
                    start = end - (day + 1) * 86400
                    res = _loki_get(
                        loki_url,
                        "/loki/api/v1/query_range",
                        {"query": rule["expr"], "start": str(start), "end": str(start + 86400), "step": step},
                    )
                    if res.get("status") != "success":
                        failures += 1
                        rows.append((name, "-", "QUERY ERROR", res.get("error", res)))
                        break
                    for s in res["data"]["result"]:
                        buckets += len(s["values"])
                        series.add(json.dumps(s["metric"], sort_keys=True))
                rows.append((name, rule.get("labels", {}).get("severity", "-"), buckets, len(series)))
    print(f"{'alert':58} {'severity':9} {'firing ' + step + ' windows':>20} {'label sets':>10}")
    for name, sev, buckets, series in rows:
        print(f"{name:58} {sev:9} {buckets!s:>20} {series!s:>10}")
    return 1 if failures else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("vendor")
    sub.add_parser("generate")
    sub.add_parser("check")
    lint = sub.add_parser("lint")
    lint.add_argument("paths", nargs="*", type=Path)
    val = sub.add_parser("validate")
    val.add_argument("files", nargs="*", type=Path)
    val.add_argument("--loki-url", default="http://localhost:3100")
    val.add_argument("--days", type=int, default=7)
    val.add_argument("--step", default="5m")
    args = parser.parse_args()

    cfg = load_config()
    if args.cmd == "vendor":
        return cmd_vendor(cfg)
    if args.cmd in ("generate", "check"):
        return cmd_generate(cfg, check=args.cmd == "check")
    if args.cmd == "lint":
        return cmd_lint([p.resolve() for p in args.paths] or [ROOT / "kubernetes"])
    files = args.files or [ROOT / out["file"] for out in cfg["outputs"]]
    return cmd_validate(files, args.loki_url, args.days, args.step)


if __name__ == "__main__":
    sys.exit(main())
