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
├── music-transcode/                # portable-player MP3 tier (script + deploy)
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
| music-transcode | — | Builds the portable-player MP3 tier (see below) |

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

### `music-transcode/`

Builds the portable-player copy of the music library. The archive keeps whatever
the indexers delivered; the player is an 80 MHz device with a 44.1 kHz-only DAC,
a ~5 MB/s USB stack and a fixed-size card, so it gets its own tree:

```
/music         (archive, ro)  ─┐
/music-manual  (rips, ro)     ─┴─► /music-ipod   MP3 V0 @ 44.1 kHz
                                                 ReplayGain (album mode)
                                                 cover.jpg, long edge ≤ 200 px
```

Two rules, decided on the **codec ffprobe reports** rather than the file
extension (`.m4a` is ALAC or AAC and only the codec knows which):

| Source | Action |
|---|---|
| lossless (FLAC/ALAC/APE/WavPack/PCM) | encode to MP3 V0, forced to 44.1 kHz |
| lossy (MP3/AAC/Vorbis/Opus) | copy through — re-encoding is a second generation of loss for nothing |

**This is where hi-res is actually stopped.** Lidarr matches quality on the
release *name* at search time and only learns the truth from file *content* at
import, so a release named `Artist-Album.1994` with no hi-res token passes a
profile that excludes 24-bit and turns out to be 24/96. Roughly 19 % of the
first real import arrived that way. No name-based rule can prevent it; the
`-ar 44100` in the script is the guard that holds.

It polls (default 600 s) rather than hooking Lidarr's import event, so hand rips
dropped into `/music-manual` are picked up with no extra wiring, and the pass is
idempotent: a destination newer than its source is skipped, and anything no
source maps to any more is pruned.

Deploy the script (it is bind-mounted, not baked into an image):

```sh
NAS_HOST=root@<nas> ./music-transcode/deploy-script.sh
```

One-shot run for testing, no loop: set `INTERVAL=0`.

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
