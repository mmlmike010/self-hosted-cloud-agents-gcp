#!/usr/bin/env bash
# Runs on every boot (GCE startup-script), so it is written to be idempotent.
set -euo pipefail
LOG_FILE="/var/log/cursor-worker-bootstrap.log"
exec > >(tee -a "$${LOG_FILE}") 2>&1
echo "Starting Cursor worker bootstrap at $(date -Is)"

if ! command -v docker >/dev/null 2>&1; then
  apt-get update
  apt-get install -y docker.io git
fi
systemctl enable --now docker

CURSOR_API_KEY=""
for attempt in {1..60}; do
  if CURSOR_API_KEY="$(gcloud secrets versions access latest \
      --project "${project_id}" --secret "${secret_id}" 2>/dev/null)"; then
    break
  fi
  echo "Waiting for Cursor API key secret version, attempt $${attempt}/60"
  sleep 10
done
if [[ -z "$${CURSOR_API_KEY}" ]]; then
  echo "Cursor API key secret was not available after waiting." >&2
  exit 1
fi

GIT_TOKEN_SECRET_ID="${git_token_secret_id}"
install -d -m 0700 /etc/cursor
install -d -m 0755 /opt/cursor/worker
if [[ ! -d /opt/cursor/worker/.git ]]; then
  if [[ -n "$${GIT_TOKEN_SECRET_ID}" ]]; then
    # Clone once with a read-only token. The token is passed as a one-off header
    # and is not written to .git/config.
    GIT_TOKEN="$(gcloud secrets versions access latest \
      --project "${project_id}" --secret "$${GIT_TOKEN_SECRET_ID}")"
    GIT_AUTH="$(printf 'x-access-token:%s' "$${GIT_TOKEN}" | base64 -w0)"
    GIT_TERMINAL_PROMPT=0 git -c http.extraHeader="Authorization: Basic $${GIT_AUTH}" \
      clone "${repository_url}" /opt/cursor/worker
    unset GIT_TOKEN GIT_AUTH
  else
    # Lab repo behavior: empty repo with an origin, so the worker derives repo=
    git -C /opt/cursor/worker init
  fi
fi
git -C /opt/cursor/worker remote remove origin 2>/dev/null || true
git -C /opt/cursor/worker remote add origin "${repository_url}"

cat >/etc/cursor/worker.env <<ENV
CURSOR_API_KEY=$${CURSOR_API_KEY}
CURSOR_WORKER_POOL_NAME=${worker_pool_name}
CURSOR_WORKER_IDLE_RELEASE_TIMEOUT=600
CURSOR_WORKER_LABELS_FILE=/etc/cursor/labels.json
ENV
chmod 0600 /etc/cursor/worker.env
unset CURSOR_API_KEY

docker rm -f cursor-worker 2>/dev/null || true
for attempt in {1..60}; do
  if gcloud auth print-access-token | docker login -u oauth2accesstoken \
        --password-stdin "https://${registry_host}" >/dev/null \
     && docker pull "${worker_image}"; then
    break
  fi
  echo "Waiting for worker image ${worker_image}, attempt $${attempt}/60"
  sleep 10
done
docker image inspect "${worker_image}" >/dev/null

# A new container is created on every run so env-file changes take effect
docker run -d \
  --name cursor-worker \
  --restart unless-stopped \
  --env-file /etc/cursor/worker.env \
  --volume /opt/cursor/worker:/workspace \
  "${worker_image}"

echo "Cursor worker bootstrap complete at $(date -Is)"
