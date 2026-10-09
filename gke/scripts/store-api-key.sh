#!/usr/bin/env bash
# Secret Manager is the source of truth. The Kubernetes Secret is created from it
# over stdin, so the key never appears in command arguments. Rerun to rotate.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

gcloud secrets describe "${SECRET_ID}" >/dev/null 2>&1 ||
  gcloud secrets create "${SECRET_ID}" --replication-policy automatic

if [[ -n "${CURSOR_API_KEY:-}" || "${1:-}" == "--new-version" ]] ||
  ! gcloud secrets versions access latest --secret "${SECRET_ID}" >/dev/null 2>&1; then
  require_api_key
  printf '%s' "${CURSOR_API_KEY}" | gcloud secrets versions add "${SECRET_ID}" --data-file=-
fi

kubectl get namespace "${K8S_NAMESPACE}" >/dev/null 2>&1 ||
  kubectl create namespace "${K8S_NAMESPACE}"

gcloud secrets versions access latest --secret "${SECRET_ID}" |
  kubectl -n "${K8S_NAMESPACE}" create secret generic "${K8S_SECRET_NAME}" \
    --from-file=api-key=/dev/stdin --dry-run=client -o yaml |
  kubectl apply -f -
