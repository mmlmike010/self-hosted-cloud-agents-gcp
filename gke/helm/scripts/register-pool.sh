#!/usr/bin/env bash
# Registers the pool name so it shows in the Any repo picker with zero workers.
set -euo pipefail

: "${CURSOR_API_KEY:?CURSOR_API_KEY must be set to a Cursor service account API key}"
POOL_NAME="${POOL_NAME:-gke-workers}"

curl --request POST \
  --url "https://api.cursor.com/v0/private-workers/pools" \
  -u "${CURSOR_API_KEY}:" \
  --header 'Content-Type: application/json' \
  --data "{\"scope\":\"team\",\"poolName\":\"${POOL_NAME}\"}"
echo
