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
├── deploy.sh                       # push a stack to Portainer, secrets injected from SOPS
├── .env.example                    # environment variables (secrets go in Portainer)
└── README.md
```

## Deploy

`deploy.sh` pushes a stack to Portainer with its **secret** env (the *arr API
keys) decrypted from a SOPS-encrypted file at deploy time — nothing secret is
committed here. Compose comes from `stacks/<name>.yml`; non-secret env (domain,
host) is preserved from the running stack.

```sh
PORTAINER_URL=https://<nas>:9443 \
SECRETS_FILE=/path/to/media.enc.yaml \
./deploy.sh homepage
# DRY_RUN=1 ... ./deploy.sh homepage    # show the env diff, change nothing
```

SOPS key `sonarr-api-key` maps to stack env `HOMEPAGE_VAR_SONARR_KEY`, etc. See
the `deploy.sh` header for all env vars (Portainer user/password-file default to
`nixie` / `/run/secrets/portainer`).

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
