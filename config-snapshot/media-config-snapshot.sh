#!/usr/bin/env bash
# Snapshot the running configuration of the *arr apps to JSON.
#
# WHY
# The compose files in this repo describe what CONTAINERS run. They say nothing
# about how the apps are configured, and that configuration is where most of the
# thinking lives: quality profiles, naming formats, indexer routing, categories.
# All of it is SQLite inside the config share. Restoring a database blob into a
# version-compatible app is a worse recovery story than reading what the settings
# were and re-entering them, which is the same reasoning that puts a plain-text
# album manifest alongside the music library rather than trusting a DB restore.
#
# WHY THE OUTPUT IS NOT COMMITTED
# This repo is public. Even though the *arr APIs mask secret fields on read
# (apiKey comes back as "********"), the dumps still carry internal hostnames and
# addresses. The snapshot is therefore written INTO the config share on the NAS,
# where it rides along with the existing offsite backup of that share, and never
# into git. Only this script is committed.
#
#   NAS_HOST=root@<nas> ./config-snapshot/media-config-snapshot.sh
#   OUT=./local-dir NAS_HOST=... ./config-snapshot/media-config-snapshot.sh   # dump locally instead
set -euo pipefail

HOST="${NAS_HOST:?set NAS_HOST, e.g. root@nas.example}"
ADDR="${NAS_ADDR:-${HOST#*@}}"
REMOTE_OUT="${REMOTE_OUT:-/volume1/configs/media-config-snapshot}"
OUT="${OUT:-}"
STAMP=$(date -u +%Y-%m-%dT%H%M%SZ)

# app:port:apiversion — the endpoints worth capturing differ slightly per app,
# so each is listed explicitly rather than guessed.
APPS=(
  "lidarr:8686:v1:qualityprofile metadataprofile config/naming config/mediamanagement rootfolder indexer downloadclient metadata artist"
  "radarr:7878:v3:qualityprofile config/naming config/mediamanagement rootfolder indexer downloadclient"
  "sonarr:8989:v3:qualityprofile config/naming config/mediamanagement rootfolder indexer downloadclient"
)

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
mkdir -p "$work/$STAMP"

for spec in "${APPS[@]}"; do
  IFS=: read -r app port apiv endpoints <<<"$spec"
  key=$(ssh -n "$HOST" "sed -n 's|.*<ApiKey>\\([^<]*\\)</ApiKey>.*|\\1|p' /volume1/configs/$app/config.xml" 2>/dev/null || true)
  [ -n "$key" ] || { echo "  $app: no api key, skipping" >&2; continue; }
  for ep in $endpoints; do
    name="${app}.${ep//\//-}.json"
    if curl -sf --max-time 30 -H "X-Api-Key: $key" "http://$ADDR:$port/api/$apiv/$ep" \
         | jq '.' > "$work/$STAMP/$name" 2>/dev/null; then
      printf '  %-10s %-24s %s bytes\n' "$app" "$ep" "$(wc -c < "$work/$STAMP/$name")"
    else
      rm -f "$work/$STAMP/$name"; echo "  $app: $ep FAILED" >&2
    fi
  done
done

# NZBHydra2 keeps its own YAML rather than exposing config over the API. It is
# already inside the config share, so copy it verbatim; its secrets are
# {OBF}-obfuscated in place.
ssh -n "$HOST" 'cat /volume1/configs/nzbhydra2/nzbhydra.yml' > "$work/$STAMP/nzbhydra.yml" 2>/dev/null \
  && printf '  %-10s %-24s %s bytes\n' nzbhydra2 nzbhydra.yml "$(wc -c < "$work/$STAMP/nzbhydra.yml")"

# A human-readable digest, so recovery does not depend on reading raw JSON.
{
  echo "media stack configuration snapshot — $STAMP"
  echo
  for f in "$work/$STAMP"/*.qualityprofile.json "$work/$STAMP"/*qualityprofile.json; do
    [ -f "$f" ] || continue
    echo "## $(basename "$f" .json)"
    jq -r '.[] | "  \(.name) (cutoff=\(.cutoff) upgrade=\(.upgradeAllowed))\n    allowed: " +
      ([.items[] | if .quality then (if .allowed then .quality.name else empty end)
                   else (.items[] | if .allowed then .quality.name else empty end) end] | join(", "))' "$f" 2>/dev/null
  done
  for f in "$work/$STAMP"/*.config-naming.json; do
    [ -f "$f" ] || continue
    echo "## $(basename "$f" .json)"
    jq -r '"  rename=\(.renameTracks // .renameEpisodes // .renameMovies)  replaceIllegal=\(.replaceIllegalCharacters)",
           "  " + ((.standardTrackFormat // .standardEpisodeFormat // .standardMovieFormat) // "-"),
           "  " + ((.multiDiscTrackFormat // "") | tostring)' "$f" 2>/dev/null
  done
  for f in "$work/$STAMP"/*.indexer.json; do
    [ -f "$f" ] || continue
    echo "## $(basename "$f" .json)"
    jq -r '.[] | "  \(.name) enabled=\(.enableRss or .enableAutomaticSearch) cats=" +
      ([.fields[] | select(.name=="categories").value] | first | tostring)' "$f" 2>/dev/null
  done
} > "$work/$STAMP/SUMMARY.txt"

if [ -n "$OUT" ]; then
  mkdir -p "$OUT"; cp -r "$work/$STAMP" "$OUT/"
  echo "wrote $OUT/$STAMP"
else
  ssh -n "$HOST" "mkdir -p '$REMOTE_OUT'"
  tar -C "$work" -cf - "$STAMP" | ssh "$HOST" "tar -xf - -C '$REMOTE_OUT'"
  # Keep the last 12 snapshots; they are a few hundred KB each.
  ssh -n "$HOST" "ls -1d '$REMOTE_OUT'/*/ 2>/dev/null | head -n -12 | xargs -r rm -rf"
  echo "wrote $REMOTE_OUT/$STAMP on $HOST (inside the backed-up config share)"
fi
