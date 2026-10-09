#!/usr/bin/env bash
# Copies the key from Secret Manager into a Kubernetes Secret without the key
# appearing in command arguments. Safe to rerun after rotating the key.
set -euo pipefail

SECRET_ID="${SECRET_ID:-cursor-worker-api-key}"
K8S_NAMESPACE="${K8S_NAMESPACE:-cursord}"
K8S_API_KEY_SECRET="${K8S_API_KEY_SECRET:-cursor-workers-api-key}"

if ! kubectl get namespace "${K8S_NAMESPACE}" >/dev/null 2>&1; then
  kubectl create namespace "${K8S_NAMESPACE}"
fi

gcloud secrets versions access latest --secret "${SECRET_ID}" \
  | kubectl -n "${K8S_NAMESPACE}" create secret generic "${K8S_API_KEY_SECRET}" \
      --from-file=api-key=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f -
