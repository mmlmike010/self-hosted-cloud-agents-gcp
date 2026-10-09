#!/usr/bin/env bash
# Installs or upgrades the k8s-workers chart from its GitHub release.
# The repo files are the source of truth, so rerun this after any change
# (new TAG, edited values.yaml, VALUES_OVERLAYS) instead of using --reuse-values.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

helm upgrade --install "${HELM_RELEASE}" "${CHART_URL}" \
  --namespace "${K8S_NAMESPACE}" \
  "${VALUES_ARGS[@]}"
