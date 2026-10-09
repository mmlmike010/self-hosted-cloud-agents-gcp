#!/usr/bin/env bash
# Sourced by the other gke/scripts. Reads ../../.env for anything not already exported.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GKE_DIR="${ROOT_DIR}/gke"

if [[ -f "${ROOT_DIR}/.env" ]]; then
  while IFS='=' read -r key value; do
    [[ "${key}" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [[ -n "${!key:-}" ]] || export "${key}=${value}"
  done <"${ROOT_DIR}/.env"
fi

: "${PROJECT_ID:?Set PROJECT_ID in .env or the environment}"
if [[ "${PROJECT_ID}" == "PROJECT_ID" ]]; then
  echo "Replace the PROJECT_ID placeholder with your project ID." >&2
  exit 1
fi

export REGION="${REGION:-us-east4}"
export ZONE="${ZONE:-us-east4-a}"
export AR_REPO="${AR_REPO:-cursor-workers}"
export IMAGE_NAME="${IMAGE_NAME:-cursor-self-hosted-worker}"
export TAG="${TAG:-v1}"
export IMAGE_REPO="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}"
export SECRET_ID="${SECRET_ID:-cursor-worker-api-key}"

export GKE_CLUSTER="${GKE_CLUSTER:-cursor-workers}"
export GKE_NETWORK="${GKE_NETWORK:-cursor-workers-vpc}"
export GKE_SUBNET="${GKE_SUBNET:-cursor-workers-subnet}"
export GKE_SUBNET_RANGE="${GKE_SUBNET_RANGE:-10.20.0.0/20}"
export GKE_ROUTER="${GKE_ROUTER:-cursor-workers-router}"
export GKE_NAT="${GKE_NAT:-cursor-workers-nat}"
export GKE_NAT_IP="${GKE_NAT_IP:-cursor-workers-nat-ip}"
export GKE_NODE_SA_NAME="${GKE_NODE_SA_NAME:-cursor-gke-nodes}"
export GKE_NODE_SA="${GKE_NODE_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
export GKE_MACHINE_TYPE="${GKE_MACHINE_TYPE:-e2-standard-4}"
export GKE_MIN_NODES="${GKE_MIN_NODES:-1}"
export GKE_MAX_NODES="${GKE_MAX_NODES:-5}"

export K8S_NAMESPACE="${K8S_NAMESPACE:-cursord}"
export K8S_SECRET_NAME="${K8S_SECRET_NAME:-cursor-workers-api-key}"
export HELM_RELEASE="${HELM_RELEASE:-gke-workers}"
export GKE_POOL="${GKE_POOL:-gke-workers}"
export CHART_VERSION="${CHART_VERSION:-0.2.2}"
export CHART_URL="${CHART_URL:-https://github.com/anysphere/k8s-workers/releases/download/v${CHART_VERSION}/k8s-workers-${CHART_VERSION}.tgz}"

# Space-separated overlay files under gke/, for example "values-clone-git-repos.yaml"
export VALUES_OVERLAYS="${VALUES_OVERLAYS:-}"

VALUES_ARGS=(-f "${GKE_DIR}/values.yaml")
for overlay in ${VALUES_OVERLAYS}; do
  VALUES_ARGS+=(-f "${GKE_DIR}/${overlay}")
done
VALUES_ARGS+=(
  --set "image.repository=${IMAGE_REPO}"
  --set "image.tag=${TAG}"
  --set "pool=${GKE_POOL}"
  --set "auth.existingSecret=${K8S_SECRET_NAME}"
)

require_api_key() {
  if [[ -z "${CURSOR_API_KEY:-}" ]]; then
    read -rsp "Cursor service account API key: " CURSOR_API_KEY
    echo
    export CURSOR_API_KEY
  fi
}
