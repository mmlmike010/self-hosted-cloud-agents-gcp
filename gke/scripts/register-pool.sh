#!/usr/bin/env bash
# Registers the any-repo pool so it stays in the "Any repo" picker with zero workers.
# https://cursor.com/docs/cloud-agent/api/endpoints#register-a-pool
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
require_api_key

curl --fail-with-body --silent --show-error --request POST \
  --url "https://api.cursor.com/v0/private-workers/pools" \
  -u "${CURSOR_API_KEY}:" \
  --header 'Content-Type: application/json' \
  --data "{\"scope\":\"team\",\"poolName\":\"${GKE_POOL}\"}"
echo
