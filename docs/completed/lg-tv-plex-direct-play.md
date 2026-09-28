# LG TV Plex Direct Play

> Operational reference for Plex playback from an LG OLED on the TV VLAN
> (`192.168.0.0/24`) to the homelab media stack (`192.168.5.0/24`).

## Problem Summary

An LG OLED TV (`192.168.0.77`) on a separate VLAN was buffering heavily on Plex
even with local-network playback expected. Investigation found four contributing
factors; network issues were the primary bottleneck.

| #   | Root cause                                                              | Fix                                                                            | Status            |
| --- | ----------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------- |
| 1   | Plex (in-pod) treated all physical-LAN clients as remote/WAN            | Set **LAN Networks** (`LanNetworksBandwidth`) + `externalTrafficPolicy: Local` | Fixed (see below) |
| 2   | LAN DNS for `plex.securimancy.com` hairpinned through Cloudflare tunnel | Added `envoy-internal` parentRef alongside `envoy-external`                    | Fixed in GitOps   |
| 3   | UniFi firewall blocked TV VLAN → homelab                                | Allow rules on UniFi                                                           | Fixed manually    |
| 4   | Some library content uses DTS/TrueHD, forcing Plex audio remux on LG    | Acquisition tuning + library remediation (see below)                           | Ongoing           |

After network fixes, playback is healthy. Remaining codec mismatches cause audio
remux (CPU on Plex server), not WAN-style buffering.

## Network Architecture

```
LG OLED TV (192.168.0.77)
  TV VLAN 192.168.0.0/24
        │
        │  UniFi firewall (must allow → homelab)
        ▼
Homelab 192.168.5.0/24
  ├── 192.168.5.21:32400  Plex LoadBalancer (direct, best for local=1)
  └── 192.168.5.10:443    envoy-internal (hostname path via LAN DNS)
```

### Local vs remote classification (root cause #1)

Plex runs as a pod, so its only NIC is on the **pod CIDR** (`10.42.0.0/16`).
With the **LAN Networks** field empty, Plex auto-detected only that pod subnet as
"local" and classified every physical-LAN client (`192.168.x`) as remote/WAN —
applying remote bandwidth caps and forcing transcodes even for LAN playback.

Two settings fix this:

1. **LAN Networks** (`LanNetworksBandwidth`) — tells Plex which subnets to treat
   as local regardless of its own NIC. GitOps-managed via the image's generic
   preference injector (`home-operations/plex` entrypoint applies any
   `PLEX_PREFERENCE_<N>="Key=Value"` env var to `Preferences.xml` on every start,
   so it survives a config PVC rebuild) — `helmrelease.yaml`:

    ```yaml
    PLEX_PREFERENCE_1: "LanNetworksBandwidth=192.168.0.0/24,192.168.1.0/24,192.168.5.0/24"
    ```

    > Do **not** add the pod CIDR (`10.42.0.0/16`) here — remote clients arriving
    > via the Cloudflare tunnel → `envoy-external` also originate from that CIDR,
    > so whitelisting it would mark genuine remote streams as local.

    To set it live without a restart (e.g. before the next reconcile), PUT it via
    the Plex API:

    ```sh
    TOKEN=$(kubectl exec -n media deploy/plex -c app -- \
      grep -o 'PlexOnlineToken="[^"]*"' \
      "/config/Library/Application Support/Plex Media Server/Preferences.xml" \
      | cut -d'"' -f2)
    curl -s -X PUT "http://192.168.5.21:32400/:/prefs?LanNetworksBandwidth=192.168.0.0%2F24%2C192.168.1.0%2F24%2C192.168.5.0%2F24&X-Plex-Token=${TOKEN}"
    ```

    Note: because `PLEX_PREFERENCE_*` re-applies on every start, any later change
    made in the Plex UI is reverted to the env value on the next restart.

2. **`externalTrafficPolicy: Local`** — `kubernetes/apps/media/plex/app/helmrelease.yaml`
   (GitOps). The `plex` LoadBalancer otherwise SNATs clients to a node IP; `Local`
   preserves the real client source IP so it matches the LAN Networks list above
   on direct `192.168.5.21:32400` connections. Cilium L2 announces the LB IP from
   the node running the Plex pod (brief blip on pod reschedule — acceptable).

**Direct connection URL** — same file, so LAN clients prefer the direct path:

```yaml
PLEX_ADVERTISE_URL: http://192.168.5.21:32400,https://plex.${SECRET_DOMAIN}:443,...
```

**LAN ingress** — same file, route `parentRefs`:

```yaml
parentRefs:
    - name: envoy-internal # LAN DNS → 192.168.5.10:443
      namespace: network
    - name: envoy-external # public DNS → Cloudflare tunnel
      namespace: network
```

Private DNS (UniFi) resolves `plex.securimancy.com` to `192.168.5.10` so LAN
clients never hairpin through Cloudflare.

## UniFi Firewall Rules

Allow the TV VLAN (`192.168.0.0/24`) to reach these homelab targets:

| Destination    | Port(s)         | Purpose                                  |
| -------------- | --------------- | ---------------------------------------- |
| `192.168.5.21` | TCP 32400       | Direct Plex LB — preferred for `local=1` |
| `192.168.5.10` | TCP 443         | envoy-internal — hostname/HTTPS path     |
| `192.168.5.21` | UDP 32410–32414 | Optional GDM discovery                   |

Rule direction: **TV VLAN → homelab**. Verify with a connectivity test from a
device on the TV VLAN before troubleshooting Plex client settings.

## LG Client Setup

The Plex app on webOS cannot easily pin a server IP. Two workable approaches:

### Option A — Direct IP (recommended for `local=1`)

1. Add server manually: `http://192.168.5.21:32400`
2. In Plex app settings → **Network**, enable **Allow insecure connections**
   (required for plain HTTP to the LB IP)
3. Confirm in Plex dashboard: client shows `local=1`, `location=local`

### Option B — Hostname via LAN DNS

1. Connect to `https://plex.securimancy.com` (resolves to `192.168.5.10` on LAN)
2. With **LAN Networks** configured (see root cause #1), sessions from LAN
   subnets now report `local=1` (correct bandwidth/quality) even on this path.
   The session may still show `location=wan` because that reflects the
   connection URL category (hostname/reverse-proxy), not a Cloudflare hairpin —
   `location=lan` only appears when the client uses the direct advertised URL
   (`http://192.168.5.21:32400`), e.g. via GDM discovery

### LG Direct Play codec compatibility

| Direct Play friendly  | Avoid (forces remux/transcode on LG) |
| --------------------- | ------------------------------------ |
| H.264 / HEVC video    | —                                    |
| AAC, EAC3 (DD+) audio | DTS, DTS-HD, TrueHD, TrueHD Atmos    |
| —                     | FLAC, PCM                            |

## Media Acquisition (Recyclarr / Sonarr / Radarr / Seerr)

Recyclarr config: `kubernetes/apps/media/recyclarr/app/resources/recyclarr.yml`

Recyclarr syncs TRaSH Guides quality profiles and custom-format scores into
Sonarr and Radarr. It only affects **future** grabs and upgrades triggered by
`*arr`; it does not rewrite existing files.

### Seerr defaults (recommended)

| Service | Default quality profile |
| ------- | ----------------------- |
| Sonarr  | **WEB-1080p**           |
| Radarr  | **SQP-1 WEB (1080p)**   |

Use 2160p profiles selectively for premium content where the TV and network
can handle it.

### Sonarr profiles

| Profile   | trash_id                           | Use                 |
| --------- | ---------------------------------- | ------------------- |
| WEB-1080p | `72dae194fc92bf828f32cde7744e51a1` | **LG default**      |
| WEB-2160p | `d1498e7d189fbe6c7110ceaabb7473e6` | Selective / premium |

Custom format groups: **Season Packs**, **Golden Rule HD** (both profiles).

### Radarr profiles

| Profile           | trash_id                           | Use            |
| ----------------- | ---------------------------------- | -------------- |
| SQP-1 WEB (1080p) | `90a3370d2d30cbaf08d9c23b856a12c8` | **LG default** |
| SQP-1 (2160p)     | `5128baeb2b081b72126bc8482b2a86a0` | Premium        |

Custom format groups: **Golden Rule HD** (1080p), **Golden Rule UHD** (2160p).

Quality definition type: `sqp-uhd`.

### LG audio scoring (both Sonarr and Radarr)

Applied to all four profiles above:

| Custom format                                  | Score  |
| ---------------------------------------------- | ------ |
| AAC                                            | +3000  |
| DD+ / EAC3                                     | +500   |
| DTS family (DTS, DTS-HD MA/HRA, DTS-ES, DTS X) | −15000 |
| TrueHD / TrueHD Atmos                          | −15000 |
| FLAC / PCM                                     | −10000 |
| x265 (HD)                                      | +300   |

Additional: **DV (w/o HDR fallback)** scored −10000 on **2160p profiles only**
(Sonarr WEB-2160p, Radarr SQP-1 2160p).

After editing `recyclarr.yml`, wait for the Recyclarr CronJob to sync or
trigger a manual sync, then verify profiles in Sonarr/Radarr UI.
