#!/usr/bin/env bash
# Custom VPC with Private Google Access, plus Cloud NAT on one static egress IP.
# --nat-all-subnet-ip-ranges also covers the Pod and Service secondary ranges.
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

gcloud compute networks describe "${GKE_NETWORK}" >/dev/null 2>&1 ||
  gcloud compute networks create "${GKE_NETWORK}" --subnet-mode custom

gcloud compute networks subnets describe "${GKE_SUBNET}" --region "${REGION}" >/dev/null 2>&1 ||
  gcloud compute networks subnets create "${GKE_SUBNET}" \
    --network "${GKE_NETWORK}" --region "${REGION}" \
    --range "${GKE_SUBNET_RANGE}" --enable-private-ip-google-access

gcloud compute routers describe "${GKE_ROUTER}" --region "${REGION}" >/dev/null 2>&1 ||
  gcloud compute routers create "${GKE_ROUTER}" \
    --network "${GKE_NETWORK}" --region "${REGION}"

gcloud compute addresses describe "${GKE_NAT_IP}" --region "${REGION}" >/dev/null 2>&1 ||
  gcloud compute addresses create "${GKE_NAT_IP}" --region "${REGION}"

gcloud compute routers nats describe "${GKE_NAT}" --router "${GKE_ROUTER}" --region "${REGION}" >/dev/null 2>&1 ||
  gcloud compute routers nats create "${GKE_NAT}" \
    --router "${GKE_ROUTER}" --region "${REGION}" \
    --nat-all-subnet-ip-ranges --nat-external-ip-pool "${GKE_NAT_IP}"

echo "Static egress IP to allowlist:"
gcloud compute addresses describe "${GKE_NAT_IP}" --region "${REGION}" --format 'value(address)'
