#!/usr/bin/env bash
# Deploy a media stack to Portainer with secrets injected from a SOPS file.
#
# Compose comes from stacks/<name>.yml (source of truth). Non-secret env is
# preserved from the running stack. Secret env (the *arr API keys) is decrypted
# from $SECRETS_FILE at deploy time and injected via the Portainer API — nothing
# secret is committed to this repo.
#
# SOPS key `sonarr-api-key` maps to stack env `HOMEPAGE_VAR_SONARR_KEY`, etc.
#
# Usage:
#   PORTAINER_URL=https://host:9443 SECRETS_FILE=/path/media.enc.yaml ./deploy.sh homepage
#   DRY_RUN=1 ... ./deploy.sh homepage      # show the env/compose diff, no changes
#
# Env vars:
#   PORTAINER_URL      (required)  e.g. https://10.0.0.108:19943
#   SECRETS_FILE       (required)  SOPS-encrypted yaml (age); decrypted with your key
#   PORTAINER_USER     (default: nixie)
#   PORTAINER_PW_FILE  (default: /run/secrets/portainer)
set -euo pipefail
STACK="${1:-homepage}"
: "${PORTAINER_URL:?set PORTAINER_URL}"
: "${SECRETS_FILE:?set SECRETS_FILE (SOPS-encrypted media secrets)}"
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

# --- assemble env: current values, arr keys overridden from SOPS ---
cur_env=$(c "${A[@]}" "$PORTAINER_URL/api/stacks/$sid" | jq '.Env // []')
ovr=$(sops decrypt --output-type json "$SECRETS_FILE" | jq -c '
  to_entries | map({ name: ("HOMEPAGE_VAR_" + (.key|ascii_upcase|sub("-API-KEY";"")|gsub("-";"_")) + "_KEY"), value }) ')
env_json=$(jq -c --argjson o "$ovr" '
  ((map({(.name):.value})|add) + ($o|map({(.name):.value})|add)) | to_entries | map({name:.key, value:.value})
' <<<"$cur_env")

if [ "${DRY_RUN:-0}" = 1 ]; then
  echo "stack=$STACK id=$sid endpoint=$eid"
  echo "env var names after merge:"; jq -r '.[].name' <<<"$env_json" | sed 's/^/  /'
  echo "arr-key env being set from SOPS (values hidden):"; jq -r '.[].name' <<<"$ovr" | sed 's/^/  /'
  exit 0
fi

# --- push update (repo compose + merged env) ---
body=$(jq -nc --rawfile file "$COMPOSE" --argjson env "$env_json" \
  '{stackFileContent:$file, env:$env, prune:false, pullImage:false}')
resp=$(c -X PUT "${A[@]}" -H 'Content-Type: application/json' \
  "$PORTAINER_URL/api/stacks/$sid?endpointId=$eid" --data-binary "$body")
jq -e '.Id' >/dev/null 2>&1 <<<"$resp" \
  && echo "deployed '$STACK' (stack $sid) with secrets from SOPS" \
  || { echo "deploy failed: $resp" >&2; exit 1; }
