#!/usr/bin/env bash
# Prints the manifests install.sh would apply, without touching the cluster.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

helm template "${HELM_RELEASE}" "${CHART_URL}" \
  --namespace "${K8S_NAMESPACE}" \
  "${VALUES_ARGS[@]}"
