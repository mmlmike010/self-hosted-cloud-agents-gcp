#!/usr/bin/env bash
# Renders the chart locally with the repo's values. No cluster access needed.
set -euo pipefail

IMAGE_REPO="${IMAGE_REPO:-REGION-docker.pkg.dev/PROJECT_ID/cursor-workers/cursor-self-hosted-worker}"
TAG="${TAG:-v1}"
K8S_NAMESPACE="${K8S_NAMESPACE:-cursord}"
HELM_RELEASE="${HELM_RELEASE:-gke-workers}"
CHART="${CURSOR_WORKERS_CHART:-oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers}"
CHART_VERSION="${CURSOR_WORKERS_CHART_VERSION:-0.2.2}"
VALUES_FILE="${GKE_VALUES_FILE:-gke/helm/values.yaml}"

helm template "${HELM_RELEASE}" "${CHART}" \
  --version "${CHART_VERSION}" \
  --namespace "${K8S_NAMESPACE}" \
  --values "${VALUES_FILE}" \
  --set image.repository="${IMAGE_REPO}" \
  --set image.tag="${TAG}" \
  "$@"
