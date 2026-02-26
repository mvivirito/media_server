# Media Server

Docker Compose stacks for a self-hosted media server running on an **Asustor AS6704T** NAS, deployed via **Portainer**.

## Architecture

```
                    Internet
                       |
                  [Cloudflared]
                       |
                   media-net (bridge)
                       |
     ┌─────────────────┼─────────────────┐
     |                 |                  |
 [NZBHydra2]      [SABnzbd]          [BookLore]
   :5076            :8080               :6060
     |                 |                  |
     |         ┌───────┴───────┐      [MariaDB]
     |         |               |
  [Radarr]  [Sonarr]
   :7878     :8989
```

All services share the `media-net` external bridge network.

## Stacks

### Main Stack — `docker-compose.yml`

Automated Usenet media pipeline for movies and TV.

| Service | Port | Description |
|---------|------|-------------|
| **NZBHydra2** | 5076 | Unified NZB indexer search proxy |
| **SABnzbd** | 8080 | Usenet download client |
| **Radarr** | 7878 | Movie monitoring — searches NZBHydra2, sends to SABnzbd |
| **Sonarr** | 8989 | TV show monitoring — searches NZBHydra2, sends to SABnzbd |
| **Cloudflared** | — | Cloudflare tunnel for secure remote access |

### BookLore Stack — `booklore.yml`

Book library management.

| Service | Port | Description |
|---------|------|-------------|
| **BookLore** | 6060 | Book library management app |
| **MariaDB** | — | 11.4.5 database backend for BookLore |

## NAS Volume Layout

```
/volume1/
  └── configs/           # Persistent config for all services
        ├── sabnzbd/
        ├── radarr/
        ├── sonarr/
        ├── nzbhydra2/
        ├── cloudflared/
        ├── booklore/
        └── mariadb/

/volume2/ (Warehouse-1)
  ├── Downloads/          # SABnzbd download target
  └── Warehouse-1/
      └── movies/         # Radarr movie library

/volume3/ (Warehouse-2)
  └── Warehouse-2/
      ├── tv/             # Sonarr TV library
      ├── books/          # BookLore library
      │   └── bookdrop/   # Auto-import drop folder
      └── library/
          └── Uncategorized/
```

## Configuration

### `.env`

Contains the shared config base path — no secrets:

```env
CONFIG_BASE=/volume1/configs
```

### Secrets (Portainer environment variables)

These are **not** stored in the repo. Set them in Portainer:

| Variable | Stack | Purpose |
|----------|-------|---------|
| `TOKEN` | main | Cloudflare tunnel token |
| `MYSQL_ROOT_PASS` | booklore | MariaDB root password |
| `MYSQL_PASS` | booklore | BookLore / MariaDB user password |

## Deployment

Both stacks are deployed through Portainer on the NAS. The `media-net` bridge network must exist before deploying either stack:

```bash
docker network create media-net
```

## Conventions

- All [LinuxServer.io](https://www.linuxserver.io/) containers use `PUID=1000`, `PGID=1000`, `TZ=Etc/UTC`
- All services set `restart: unless-stopped`
- Container names match service names (e.g., service `radarr` -> container `radarr`)
- Images use `:latest` tags
