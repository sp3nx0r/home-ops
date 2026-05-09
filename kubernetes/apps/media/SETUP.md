# Media Stack Setup Guide

Configuration steps for the arr media stack, ordered by dependency chain.

## 1. qBittorrent

- [x] Save path set to `/media/downloads/qbittorrent/complete`
- [x] Incomplete path set to `/media/downloads/qbittorrent/incomplete`
- [x] Categories created: `sonarr` and `radarr` with save paths under `complete/`
- [X] Verify torrenting port `50413` is forwarded on router/firewall
- LoadBalancer IP: `192.168.5.23`
- Web UI: `qbittorrent.securimancy.com`

## 2. SABnzbd

- [ ] Complete first-time setup wizard at `sabnzbd.securimancy.com`
- [ ] Add Usenet server(s)
- [ ] Create `sonarr` category with path `/media/downloads/sabnzbd/complete/sonarr`
- [ ] Create `radarr` category with path `/media/downloads/sabnzbd/complete/radarr`
- API key pre-injected via `SABNZBD__API_KEY` env var

## 3. Prowlarr

- [ ] Add indexers (torrent trackers, Usenet indexers)
- [X] Add Sonarr as app: `http://sonarr.media.svc.cluster.local` + API key
- [X] Add Radarr as app: `http://radarr.media.svc.cluster.local` + API key
- API key pre-injected via `PROWLARR__AUTH__APIKEY` env var
- Web UI: `prowlarr.securimancy.com`

## 4. Sonarr

- [X] Add root folder: `/media/tv`
- [X] Add download client: qBittorrent (`qbittorrent.media.svc.cluster.local:80`, category `sonarr`)
- [ ] Add download client: SABnzbd (`sabnzbd.media.svc.cluster.local:80`, use API key from secret)
- [X] Verify Recyclarr synced quality profiles
- API key pre-injected via `SONARR__AUTH__APIKEY` env var
- Web UI: `sonarr.securimancy.com`

## 5. Radarr

- [X] Add root folder: `/media/movies`
- [X] Add download client: qBittorrent (`qbittorrent.media.svc.cluster.local:80`, category `radarr`)
- [ ] Add download client: SABnzbd (`sabnzbd.media.svc.cluster.local:80`, use API key from secret)
- [X] Verify Recyclarr synced quality profiles
- API key pre-injected via `RADARR__AUTH__APIKEY` env var
- Web UI: `radarr.securimancy.com`

## 6. Recyclarr

- Runs automatically on schedule via CronJob-style container
- Syncs Trash Guide quality profiles to Sonarr and Radarr
- [ ] Check logs to verify profiles synced: `kubectl logs -n media deployment/recyclarr`

## 7. Bazarr

- [X] Connect to Sonarr: `http://sonarr.media.svc.cluster.local` + API key
- [X] Connect to Radarr: `http://radarr.media.svc.cluster.local` + API key
- [X] Add subtitle providers (OpenSubtitles, etc.)
- Web UI: `bazarr.securimancy.com`

## 8. Autobrr

- [ ] Add IRC networks and channels for trackers
- [ ] Create filters pointing to Sonarr/Radarr
- Session secret pre-injected via `AUTOBRR__SESSION_SECRET` env var
- Web UI: `autobrr.securimancy.com`

## 9. Seerr

- [X] Complete first-time setup wizard at `seerr.securimancy.com`
- [X] Connect to Plex for library scanning
- [X] Connect to Sonarr: `http://sonarr.media.svc.cluster.local` + API key
- [X] Connect to Radarr: `http://radarr.media.svc.cluster.local` + API key
- Web UI: `seerr.securimancy.com`

## 10. Agregarr

- [X] Configure dashboard with URLs to all apps
- Web UI: `agregarr.securimancy.com`

## Auto-configured (no manual steps)

| App | Purpose | Notes |
|-----|---------|-------|
| Qui | qBittorrent UI proxy | Connected via env vars |
| Brrpolice | qBittorrent ban list manager | Auto-connects to qBittorrent |
| Seasonpackerr | Season pack handler | Watches `/media/downloads/qbittorrent/complete/sonarr` |

## API Keys

All API keys are stored in SOPS-encrypted secrets. To retrieve a key:

## Future TODOs

- [ ] Migrate Plex config from NFS to VolSync-backed PVC
- [ ] Migrate Tautulli config from NFS to VolSync-backed PVC
- [ ] Add external access for Seerr (envoy-external) with family authentication
