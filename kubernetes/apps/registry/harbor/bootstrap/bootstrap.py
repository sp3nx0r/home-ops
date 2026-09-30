"""Idempotently apply Harbor settings that only exist in its API/DB.

CONFIG_OVERWRITE_JSON (core.configureUserSettings) covers system config such as
OIDC, but proxy-cache registries/projects, quotas, tag retention, and the GC
schedule are database objects. Each step reads current state and only creates
or updates what differs, so re-running the Job is safe.
"""

import base64
import json
import os
import sys
import time
import urllib.error
import urllib.request

GIB = 1024**3

HARBOR_URL = os.environ["HARBOR_URL"].rstrip("/")
AUTH = base64.b64encode(
    f"admin:{os.environ['HARBOR_ADMIN_PASSWORD']}".encode()
).decode()

# Sum of storage limits must stay below the Garage `harbor` bucket quota.
PROXY_CACHES = [
    {"name": "dockerhub", "type": "docker-hub", "url": "https://hub.docker.com", "storage_gib": 15},
    {"name": "ghcr", "type": "github-ghcr", "url": "https://ghcr.io", "storage_gib": 15},
]
PROJECT_QUOTAS_GIB = {"library": 10}
PROXY_RETENTION_DAYS = 90
# Harbor cron has a leading seconds field.
RETENTION_CRON = "0 0 3 * * *"
GC_CRON = "0 0 4 * * 0"


def api(method, path, body=None, ok=(200, 201)):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(f"{HARBOR_URL}/api/v2.0{path}", data=data, method=method)
    req.add_header("Authorization", f"Basic {AUTH}")
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            status = resp.status
    except urllib.error.HTTPError as err:
        raw = err.read()
        status = err.code
    if status not in ok:
        sys.exit(f"{method} {path} -> {status}: {raw.decode(errors='replace')}")
    return json.loads(raw) if raw else None


def wait_healthy(deadline_s=600):
    start = time.monotonic()
    while time.monotonic() - start < deadline_s:
        try:
            with urllib.request.urlopen(f"{HARBOR_URL}/api/v2.0/health", timeout=10) as resp:
                if json.load(resp).get("status") == "healthy":
                    return
        except (urllib.error.URLError, ValueError):
            pass
        print("waiting for Harbor to report healthy...", flush=True)
        time.sleep(10)
    sys.exit("Harbor did not become healthy in time")


def find_registry(name):
    for registry in api("GET", "/registries?page_size=100"):
        if registry["name"] == name:
            return registry["id"]
    return None


def ensure_registry(cache):
    registry_id = find_registry(cache["name"])
    if registry_id is None:
        print(f"creating registry endpoint {cache['name']}")
        api("POST", "/registries", {
            "name": cache["name"],
            "type": cache["type"],
            "url": cache["url"],
            "insecure": False,
        })
        registry_id = find_registry(cache["name"])
    return registry_id


def get_project(name):
    return api("GET", f"/projects/{name}", ok=(200, 404))


def ensure_proxy_project(cache, registry_id):
    project = get_project(cache["name"])
    if project and "project_id" in project:
        return project
    print(f"creating proxy-cache project {cache['name']}")
    api("POST", "/projects", {
        "project_name": cache["name"],
        "registry_id": registry_id,
        "storage_limit": cache["storage_gib"] * GIB,
        "metadata": {"public": "true"},
    })
    return get_project(cache["name"])


def ensure_quota(project, storage_gib):
    quotas = api("GET", f"/quotas?reference=project&reference_id={project['project_id']}")
    want = storage_gib * GIB
    if quotas and quotas[0]["hard"].get("storage") != want:
        print(f"setting {project['name']} quota to {storage_gib}GiB")
        api("PUT", f"/quotas/{quotas[0]['id']}", {"hard": {"storage": want}})


def ensure_retention(project):
    policy = {
        "algorithm": "or",
        "rules": [{
            "action": "retain",
            "template": "nDaysSinceLastPull",
            "params": {"nDaysSinceLastPull": PROXY_RETENTION_DAYS},
            "tag_selectors": [{"kind": "doublestar", "decoration": "matches", "pattern": "**"}],
            "scope_selectors": {
                "repository": [{"kind": "doublestar", "decoration": "repoMatches", "pattern": "**"}],
            },
        }],
        "trigger": {"kind": "Schedule", "settings": {"cron": RETENTION_CRON}},
        "scope": {"level": "project", "ref": project["project_id"]},
    }
    retention_id = project.get("metadata", {}).get("retention_id")
    if retention_id:
        api("PUT", f"/retentions/{retention_id}", policy)
    else:
        print(f"creating retention policy for {project['name']}")
        api("POST", "/retentions", policy)


def ensure_gc_schedule():
    body = {
        "schedule": {"type": "Custom", "cron": GC_CRON},
        "parameters": {"delete_untagged": True, "workers": 1},
    }
    current = api("GET", "/system/gc/schedule", ok=(200, 404)) or {}
    if (current.get("schedule") or {}).get("type") in (None, "", "None"):
        print("creating GC schedule")
        api("POST", "/system/gc/schedule", body)
    else:
        api("PUT", "/system/gc/schedule", body)


def main():
    wait_healthy()
    for cache in PROXY_CACHES:
        project = ensure_proxy_project(cache, ensure_registry(cache))
        ensure_quota(project, cache["storage_gib"])
        ensure_retention(project)
    for name, storage_gib in PROJECT_QUOTAS_GIB.items():
        project = get_project(name)
        if project and "project_id" in project:
            ensure_quota(project, storage_gib)
    ensure_gc_schedule()
    print("harbor bootstrap complete")


if __name__ == "__main__":
    main()
