#!/usr/bin/env bash
# Copy music-transcode.sh onto the NAS configs share, where the stack
# bind-mounts it read-only. The container reloads it on restart, so this is
# install + restart, matching the muscle memory of the other config repos.
#
#   NAS_HOST=root@<nas> ./music-transcode/deploy-script.sh
#
# Host stays out of git: this repo is public.
set -euo pipefail
HOST="${NAS_HOST:?set NAS_HOST, e.g. root@nas.example}"
DEST="${DEST:-/volume1/configs/music-transcode}"
DOCKER="${DOCKER:-/usr/local/bin/docker}"
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh "$HOST" "mkdir -p '$DEST'"
scp -q "$SELF/music-transcode.sh" "$HOST:$DEST/music-transcode.sh"
ssh -n "$HOST" "chmod 755 '$DEST/music-transcode.sh'"
echo "installed $DEST/music-transcode.sh on $HOST"
ssh -n "$HOST" "$DOCKER restart music-transcode" 2>/dev/null \
  && echo "music-transcode restarted" \
  || echo "container not running yet — deploy the stack first"
