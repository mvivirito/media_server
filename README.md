# Media Server

Docker Compose stacks for a self-hosted media server on a NAS running Docker,
deployed via Portainer. Site-specific values (domain, host, secrets) are
environment variables — see `.env.example`.

## Layout

```
media_server/
├── stacks/
│   ├── media_server.yml            # Usenet download/organize pipeline (main stack)
│   ├── booklore.yml                # ebook library + MariaDB
│   └── downloader-vpn.yml.example  # optional gluetun VPN for the downloader
├── deploy.sh                       # push a stack to Portainer (env preserved)
├── .env.example                    # environment variables (secrets go in Portainer)
└── README.md
```

## Deploy

`deploy.sh` pushes a stack to Portainer. Compose comes from `stacks/<name>.yml`;
the stack's existing Portainer env is preserved untouched, so secrets and
site-specific values live in Portainer and are never committed here.

```sh
PORTAINER_URL=https://<nas>:9443 ./deploy.sh media_server
# DRY_RUN=1 ... ./deploy.sh media_server    # show the stack/env that would be pushed
```

See the `deploy.sh` header for all env vars (Portainer user/password-file default
to `nixie` / `/run/secrets/portainer`).

## Stacks

### `stacks/media_server.yml`

| Service | Port | Description |
|---------|------|-------------|
| NZBHydra2 | 5076 | Unified NZB indexer search proxy |
| SABnzbd | 8080 | Usenet download client |
| Radarr | 7878 | Movie automation |
| Sonarr | 8989 | TV automation |
| Lidarr | 8686 | Music automation (album-oriented; see the stack comment) |
| Bazarr | 6767 | Subtitles |
| Profilarr | 6868 | Quality profiles / custom formats |
| Cloudflared | — | Optional tunnel (needs `TOKEN`) |

#### Indexer routing

Radarr, Sonarr and Lidarr each hold **one** indexer: NZBHydra2, reached over the
`media-net` container DNS name (`http://nzbhydra2:5076`, no host IP in any app's
config). Indexers are added and removed in Hydra alone, which also dedupes
results across them. Each app keeps its own category set, so Hydra serves movie,
TV and audio searches from the same pool without them bleeding into each other.

Each app also retains its previous direct indexers, **disabled**, so falling back
is one toggle per app rather than a re-entry of credentials.

One asymmetry worth knowing: Hydra advertises `audio-search` as unavailable
because it reports what all of its indexers agree on and not every indexer
implements `t=music`. Lidarr therefore falls back to a generic query with audio
categories, which returns the same results. It is not a misconfiguration.

### `stacks/booklore.yml`
BookLore (6060) + MariaDB — ebook library.

## Deployment (Portainer)

Create the shared network once, then deploy each stack and set its env vars
(see `.env.example`):

```bash
docker network create media-net
```

## Conventions

- [LinuxServer.io](https://www.linuxserver.io/) containers use `PUID=1000`,
  `PGID=1000`, `TZ=Etc/UTC`, `restart: unless-stopped`, and `no-new-privileges`.
- Container names match service names.
- Secrets and site-specific values are Portainer env vars, never committed.
