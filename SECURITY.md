# Security notes

Posture and hardening for the NAS media stack. The NAS also holds the PBS
backup datastore on `/volume1` (see the vault `asustor-nas` page), so a
container escape here reaches backups — worth keeping tight.

## Exposure map

| Service | Reachable from | Auth | Notes |
|---|---|---|---|
| Sonarr / Radarr / NZBHydra2 / Bazarr / Profilarr | LAN + Tailscale (Caddy `*.home.mvivirito.com`) | **app login — see below** | Not public; split-horizon DNS, wildcard TLS at Caddy |
| SABnzbd | LAN + Tailscale (Caddy) | host-whitelist + app | Talks to the news provider over TLS (563) |
| BookLore | LAN only (not proxied) | app login | Port 6060 |
| **Emby** (runs separately, not in this compose) | **public internet** via Cloudflare Tunnel (`emby.mvivirito.com`) | **app login only** | Biggest attack surface — see below |
| Portainer | LAN + Tailscale (Caddy) | Portainer login | Manages every container + the Docker socket |
| node-exporter | LAN `:9100` | none (read-only metrics) | Fleet convention; scraped by 10.0.0.7 |

## Applied in this repo

- **`no-new-privileges:true`** on every container — blocks privilege escalation
  via setuid/file-caps. Compatible with the LinuxServer s6 init (it drops
  root→PUID, which `no_new_privs` does not prevent).
- **`cap_drop: ALL`** on cloudflared (needs only outbound network).
- **node-exporter** runs `read_only` with the host mounted `:ro`.
- **`.gitignore` + `.env.example`** — secrets live in Portainer stack env vars,
  never in git. No secret has ever been committed (history checked).
- **Repo made private** (GitHub) + mirrored to private Gitea. A public repo
  documenting the Usenet automation is itself an OPSEC leak.

## Recommended next (needs your action / a decision)

1. **Enable app authentication on the *arr apps.** Sonarr/Radarr/NZBHydra2/Bazarr
   default to no login; anyone on the LAN or tailnet can drive them. In each:
   Settings → General → Security → Authentication = **Forms (login page)**,
   Authentication Required = **Enabled** (not "Disabled for Local Addresses").
   This is app config, not compose — do it in each UI once.
2. **Emby is on the public internet** (via the tunnel — it runs separately, not
   in this compose). Hardening, in priority order: put **Cloudflare Access**
   (Zero Trust, free tier) in front of `emby.mvivirito.com` so unauthenticated
   requests never reach Emby; keep a strong admin password + no anonymous
   access; disable any unused remote-access/discovery features. Consider
   whether it needs to be public at all vs. Tailscale-only.
3. **VPN for the downloader (optional).** `stacks/downloader-vpn.yml.example`
   scaffolds gluetun for SABnzbd. Usenet is already TLS, so this mainly hides
   Usenet use from the ISP; enable only if you want that (costs throughput).
4. **Image pinning.** Everything except MariaDB rides `:latest` — convenient but
   a surprise upstream push lands unreviewed. If you want reproducibility, pin
   digests and drive updates with a monitor (Diun) instead of implicit pulls.
5. **node-exporter :9100** is unauthenticated on the LAN (fleet convention). If
   you want it tighter, restrict it to 10.0.0.7 in the ADM firewall.

## Secrets

Set as Portainer **stack environment variables** (never files in this repo):
`TOKEN` (Cloudflare Tunnel), `MYSQL_ROOT_PASS`, `MYSQL_PASS`. See `.env.example`.
