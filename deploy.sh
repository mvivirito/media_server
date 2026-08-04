#!/usr/bin/env bash
# Deploy a stack to Portainer from this repo's compose file.
#
# Compose comes from stacks/<name>.yml (source of truth). The stack's existing
# Portainer env is preserved as-is, so secrets/site-specific values stay in
# Portainer and are never committed to this repo.
#
# Usage:
#   PORTAINER_URL=https://host:9443 ./deploy.sh media
#   DRY_RUN=1 ... ./deploy.sh media       # show the stack/env that would be pushed
#
# Env vars:
#   PORTAINER_URL      (required)  e.g. https://nas-host:9443
#   PORTAINER_USER     (default: nixie)
#   PORTAINER_PW_FILE  (default: /run/secrets/portainer)
set -euo pipefail
STACK="${1:?usage: ./deploy.sh <stack>   (stacks/<stack>.yml)}"
: "${PORTAINER_URL:?set PORTAINER_URL}"
PUSER="${PORTAINER_USER:-nixie}"
PWFILE="${PORTAINER_PW_FILE:-/run/secrets/portainer}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="$REPO/stacks/$STACK.yml"
[ -f "$COMPOSE" ] || { echo "no compose at $COMPOSE" >&2; exit 1; }
c() { curl -sk "$@"; }   # -k: Portainer's self-signed cert

# --- auth (password from file, never on argv/stdout) ---
PW=$(cat "$PWFILE")
JWT=$(c "$PORTAINER_URL/api/auth" -H 'Content-Type: application/json' \
  -d "$(jq -nc --arg u "$PUSER" --arg p "$PW" '{username:$u,password:$p}')" | jq -r '.jwt // empty')
unset PW
[ -n "$JWT" ] || { echo "portainer auth failed" >&2; exit 1; }
A=(-H "Authorization: Bearer $JWT")

# --- locate stack ---
st=$(c "${A[@]}" "$PORTAINER_URL/api/stacks" | jq --arg n "$STACK" 'map(select(.Name==$n))[0] // empty')
[ -n "$st" ] || { echo "stack '$STACK' not found in Portainer" >&2; exit 1; }
sid=$(jq -r '.Id' <<<"$st"); eid=$(jq -r '.EndpointId' <<<"$st")

# --- env: keep exactly what the stack already has (set in the Portainer UI) ---
env_json=$(c "${A[@]}" "$PORTAINER_URL/api/stacks/$sid" | jq -c '.Env // []')

if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "stack=$STACK id=$sid endpoint=$eid"
  echo "env var names preserved:"; jq -r '.[].name' <<<"$env_json" | sed 's/^/  /'
  exit 0
fi

# --- push update (repo compose + merged env) ---
body=$(jq -nc --rawfile file "$COMPOSE" --argjson env "$env_json" \
  '{stackFileContent:$file, env:$env, prune:false, pullImage:false}')
resp=$(c -X PUT "${A[@]}" -H 'Content-Type: application/json' \
  "$PORTAINER_URL/api/stacks/$sid?endpointId=$eid" --data-binary "$body")
jq -e '.Id' >/dev/null 2>&1 <<<"$resp" \
  && echo "deployed '$STACK' (stack $sid)" \
  || { echo "deploy failed: $resp" >&2; exit 1; }
