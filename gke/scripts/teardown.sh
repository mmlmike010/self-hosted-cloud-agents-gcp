#!/usr/bin/env bash
# Deletes everything Path B created. gcloud asks before each delete.
# If Path A runs in the same project, keep the shared registry and secret:
#   KEEP_SHARED=1 ./gke/scripts/teardown.sh
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

helm uninstall "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" || true
kubectl delete namespace "${K8S_NAMESPACE}" --ignore-not-found
gcloud container clusters delete "${GKE_CLUSTER}" --location "${ZONE}"

if [[ "${KEEP_SHARED:-0}" != "1" ]]; then
  gcloud artifacts repositories delete "${AR_REPO}" --location "${REGION}"
  gcloud secrets delete "${SECRET_ID}"
fi

gcloud iam service-accounts delete "${GKE_NODE_SA}"
gcloud compute routers nats delete "${GKE_NAT}" --router "${GKE_ROUTER}" --region "${REGION}"
gcloud compute routers delete "${GKE_ROUTER}" --region "${REGION}"
gcloud compute addresses delete "${GKE_NAT_IP}" --region "${REGION}"
gcloud compute networks subnets delete "${GKE_SUBNET}" --region "${REGION}"
gcloud compute networks delete "${GKE_NETWORK}"
