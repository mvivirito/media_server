# Media Server

Docker Compose stacks for a self-hosted media server on a NAS running Docker,
deployed via Portainer. Site-specific values (domain, host, secrets) are
environment variables — see `.env.example`.

## Layout

```
media_server/
├── stacks/
│   ├── media.yml                   # Usenet download/organize pipeline (main stack)
│   ├── booklore.yml                # ebook library + MariaDB
│   ├── homepage.yml                # dashboard / start page
│   ├── monitoring.yml              # node-exporter (host metrics for Prometheus)
│   └── downloader-vpn.yml.example  # optional gluetun VPN for the downloader
├── homepage/config/                # Homepage's YAML config (the dashboard)
├── .env.example                    # environment variables (secrets go in Portainer)
└── README.md
```

## Stacks

### `stacks/media.yml`

| Service | Port | Description |
|---------|------|-------------|
| NZBHydra2 | 5076 | Unified NZB indexer search proxy |
| SABnzbd | 8080 | Usenet download client |
| Radarr | 7878 | Movie automation |
| Sonarr | 8989 | TV automation |
| Bazarr | 6767 | Subtitles |
| Profilarr | 6868 | Quality profiles / custom formats |
| Cloudflared | — | Optional tunnel (needs `TOKEN`) |

### `stacks/booklore.yml`
BookLore (6060) + MariaDB — ebook library.

### `stacks/homepage.yml`
[Homepage](https://gethomepage.dev) dashboard (3000). Config is the YAML under
`homepage/config/`; domain/host/keys come from `HOMEPAGE_*` env vars.

### `stacks/monitoring.yml`
Prometheus `node-exporter` (9100) — host metrics.

## Deployment (Portainer)

Create the shared network once, then deploy each stack and set its env vars
(see `.env.example`):

```bash
docker network create media-net
```

`monitoring.yml` is standalone (host networking, no `media-net`). For Homepage,
seed `${CONFIG_BASE}/homepage` from `homepage/config/`.

## Conventions

- [LinuxServer.io](https://www.linuxserver.io/) containers use `PUID=1000`,
  `PGID=1000`, `TZ=Etc/UTC`, `restart: unless-stopped`, and `no-new-privileges`.
- Container names match service names.
- Secrets and site-specific values are Portainer env vars, never committed.
