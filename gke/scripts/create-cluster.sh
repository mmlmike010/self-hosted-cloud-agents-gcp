#!/usr/bin/env bash
# Dedicated least-privilege node service account and a zonal GKE Standard cluster
# with private nodes. --num-nodes and the autoscaling limits are per zone.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

gcloud iam service-accounts describe "${GKE_NODE_SA}" >/dev/null 2>&1 ||
  gcloud iam service-accounts create "${GKE_NODE_SA_NAME}" --display-name "Cursor GKE nodes"

gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member "serviceAccount:${GKE_NODE_SA}" \
  --role roles/container.defaultNodeServiceAccount --condition None >/dev/null
gcloud artifacts repositories add-iam-policy-binding "${AR_REPO}" --location "${REGION}" \
  --member "serviceAccount:${GKE_NODE_SA}" \
  --role roles/artifactregistry.reader >/dev/null

gcloud container clusters describe "${GKE_CLUSTER}" --location "${ZONE}" >/dev/null 2>&1 ||
  gcloud container clusters create "${GKE_CLUSTER}" \
    --location "${ZONE}" \
    --network "${GKE_NETWORK}" --subnetwork "${GKE_SUBNET}" \
    --enable-ip-alias --enable-private-nodes \
    --service-account "${GKE_NODE_SA}" \
    --workload-pool "${PROJECT_ID}.svc.id.goog" \
    --enable-shielded-nodes --shielded-secure-boot \
    --machine-type "${GKE_MACHINE_TYPE}" --num-nodes 2 \
    --enable-autoscaling --min-nodes "${GKE_MIN_NODES}" --max-nodes "${GKE_MAX_NODES}"

gcloud container clusters get-credentials "${GKE_CLUSTER}" --location "${ZONE}"
kubectl get nodes
