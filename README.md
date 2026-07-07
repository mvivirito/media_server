# Media Server

Docker Compose stacks for a self-hosted media server on an **Asustor AS6704T**
NAS (`10.0.0.108`), deployed via **Portainer**. Security posture and hardening
notes live in [SECURITY.md](SECURITY.md).

> Private repo — the Usenet automation shouldn't be public. `origin` is the
> (now private) GitHub `mvivirito/media_server`; also mirrored to private Gitea
> `git.k8s.home/michael/media_server` for homelab-local backup + consistency.

## Layout

```
media_server/
├── stacks/
│   ├── media.yml                   # Usenet pipeline + playback (main stack)
│   ├── booklore.yml                # ebook library + MariaDB
│   ├── monitoring.yml              # node-exporter (host metrics → Prometheus)
│   └── downloader-vpn.yml.example  # optional gluetun VPN for SABnzbd
├── .env.example                    # env vars (secrets go in Portainer, not here)
├── .env                            # CONFIG_BASE only (non-secret)
├── README.md
└── SECURITY.md
```

## Stacks

### `stacks/media.yml` — media automation

| Service | Port | Description |
|---------|------|-------------|
| **NZBHydra2** | 5076 | Unified NZB indexer search proxy |
| **SABnzbd** | 8080 | Usenet download client |
| **Radarr** | 7878 | Movie monitoring — searches NZBHydra2, sends to SABnzbd |
| **Sonarr** | 8989 | TV monitoring — searches NZBHydra2, sends to SABnzbd |
| **Bazarr** | 6767 | Subtitles for the Radarr/Sonarr libraries |
| **Profilarr** | 6868 | Syncs quality profiles / custom formats across Radarr/Sonarr |
| **Cloudflared** | — | Cloudflare tunnel — publishes **Emby** (`emby.mvivirito.com`) remotely |

> Playback is **Emby**, which runs separately (not in this compose) and is the
> service exposed publicly through the tunnel. See SECURITY.md.

### `stacks/booklore.yml` — books

| Service | Port | Description |
|---------|------|-------------|
| **BookLore** | 6060 | Book library management |
| **MariaDB** | — | 11.4.5 database backend for BookLore |

### `stacks/monitoring.yml` — host metrics

| Service | Port | Description |
|---------|------|-------------|
| **node-exporter** | 9100 | Prometheus host metrics; scraped by the monitoring LXC (10.0.0.7) as the `nas` target |

## NAS volume layout

```
/volume1/configs/       # persistent config for every service (RAID volume)
/volume2/Downloads/     # SABnzbd download target
/volume2/Warehouse-1/movies/    # Radarr / Jellyfin movies
/volume3/Warehouse-2/tv/        # Sonarr / Jellyfin TV
/volume3/Warehouse-2/books/     # BookLore (+ bookdrop/ auto-import)
```

## Configuration

`.env` holds only the non-secret config base:

```env
CONFIG_BASE=/volume1/configs
```

Secrets (`TOKEN`, `MYSQL_ROOT_PASS`, `MYSQL_PASS`) are set as **Portainer stack
environment variables**, never committed. See `.env.example` and SECURITY.md.

## Deployment (Portainer)

The `media-net` external bridge must exist before deploying `media.yml` or
`booklore.yml`:

```bash
docker network create media-net
```

Then, per stack, in Portainer → Stacks → Add stack → upload the file from
`stacks/` (or paste its contents) and set the env vars above.

**`monitoring.yml` is standalone** (host networking, no `media-net`): deploy it
on its own and the `nas` target on <https://grafana.home.mvivirito.com> flips
green within a scrape interval. Verify: `curl -s http://10.0.0.108:9100/metrics`.

## Conventions

- [LinuxServer.io](https://www.linuxserver.io/) containers use `PUID=1000`,
  `PGID=1000`, `TZ=Etc/UTC`, `restart: unless-stopped`.
- Every service sets `no-new-privileges` (see SECURITY.md).
- Container names match service names.
- Images use `:latest` (except MariaDB, pinned) — see SECURITY.md on pinning.
