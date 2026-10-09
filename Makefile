SHELL := /bin/bash

-include .env
export

REGION ?= us-east4
ZONE ?= us-east4-a
AR_REPO ?= cursor-workers
IMAGE_NAME ?= cursor-self-hosted-worker
TAG ?= v1
PLATFORM ?= linux/amd64
SECRET_ID ?= cursor-worker-api-key
IMAGE_REPO := $(REGION)-docker.pkg.dev/$(PROJECT_ID)/$(AR_REPO)/$(IMAGE_NAME)
IMAGE := $(IMAGE_REPO):$(TAG)
LOCAL_IMAGE ?= $(IMAGE_NAME):local

GCE_NAME ?= cursor-worker-lab
GCE_POOL ?= gce-lab
GIT_TOKEN_SECRET_ID ?=
TF_DIR := gce/terraform

# Terraform reads TF_VAR_<name>, so .env drives the Compute Engine path without a tfvars file
export TF_VAR_project_id = $(PROJECT_ID)
export TF_VAR_region = $(REGION)
export TF_VAR_zone = $(ZONE)
export TF_VAR_name = $(GCE_NAME)
export TF_VAR_artifact_repository = $(AR_REPO)
export TF_VAR_worker_image_name = $(IMAGE_NAME)
export TF_VAR_worker_image_tag = $(TAG)
export TF_VAR_worker_pool_name = $(GCE_POOL)
export TF_VAR_worker_repository_url = $(WORKER_REPOSITORY_URL)
export TF_VAR_secret_id = $(SECRET_ID)
export TF_VAR_git_token_secret_id = $(GIT_TOKEN_SECRET_ID)

.PHONY: help check apis registry image docker-build docker-run pools \
	gce-git-token gce-init gce-plan gce-apply gce-put-key gce-access gce-logs gce-ssh gce-rerun gce-destroy \
	gke-network gke-cluster gke-key gke-pool gke-install gke-render gke-status gke-destroy

help:
	@echo "Shared"
	@echo "  check          Run every offline check (Terraform, ShellCheck, hadolint, Helm, kubeconform)"
	@echo "  apis           Enable the Google Cloud APIs both paths use"
	@echo "  registry       Create the Artifact Registry repo (GKE only, Terraform owns it on Compute Engine)"
	@echo "  image          Build and push the worker image to Artifact Registry"
	@echo "  docker-build   Build the worker image locally"
	@echo "  docker-run     Run one any-repo worker locally (needs CURSOR_API_KEY)"
	@echo "  pools          List Team Pools and worker counts from the Cursor API"
	@echo "Compute Engine + Docker (gce/terraform/README.md)"
	@echo "  gce-git-token  Store a read-only Git token in Secret Manager (optional)"
	@echo "  gce-init, gce-plan, gce-apply, gce-destroy"
	@echo "  gce-put-key    Add the Cursor API key as a Secret Manager version"
	@echo "  gce-access     Grant ADMIN_MEMBER IAP SSH with OS Login"
	@echo "  gce-logs       Show the startup script output from the serial console"
	@echo "  gce-ssh        SSH to the worker VM through IAP"
	@echo "  gce-rerun      Rerun the startup script (after key rotation or image push)"
	@echo "GKE + Helm (gke/helm/README.md)"
	@echo "  gke-network, gke-cluster, gke-key, gke-pool, gke-install, gke-render, gke-status, gke-destroy"

check:
	./scripts/check.sh

apis:
	gcloud services enable compute.googleapis.com artifactregistry.googleapis.com \
		secretmanager.googleapis.com iap.googleapis.com container.googleapis.com \
		--project "$(PROJECT_ID)"

registry:
	gcloud artifacts repositories describe "$(AR_REPO)" --location "$(REGION)" >/dev/null 2>&1 || \
		gcloud artifacts repositories create "$(AR_REPO)" --location "$(REGION)" \
		--repository-format docker --description "Cursor self-hosted worker images"

image:
	gcloud auth configure-docker "$(REGION)-docker.pkg.dev" --quiet
	docker buildx build --platform "$(PLATFORM)" -f docker/Dockerfile -t "$(IMAGE)" --push .

docker-build:
	docker build -f docker/Dockerfile -t "$(LOCAL_IMAGE)" .

docker-run:
	@if [[ -z "$${CURSOR_API_KEY:-}" ]]; then echo "Export CURSOR_API_KEY first."; exit 1; fi
	docker run --rm --env CURSOR_API_KEY --env CURSOR_WORKER_POOL_NAME=local-lab "$(LOCAL_IMAGE)"

pools:
	@if [[ -z "$${CURSOR_API_KEY:-}" ]]; then echo "Export CURSOR_API_KEY first."; exit 1; fi
	@curl -fsS -u "$${CURSOR_API_KEY}:" "https://api.cursor.com/v0/private-workers/pools?scope=team_pool" | jq .

gce-git-token:
	gcloud secrets describe cursor-git-read-token >/dev/null 2>&1 || \
		gcloud secrets create cursor-git-read-token --replication-policy automatic
	@read -rsp "Read-only Git token: " GIT_READ_TOKEN; echo; \
		printf '%s' "$$GIT_READ_TOKEN" | gcloud secrets versions add cursor-git-read-token --data-file=-
	@echo "Set GIT_TOKEN_SECRET_ID=cursor-git-read-token in .env"

gce-init:
	terraform -chdir=$(TF_DIR) init

gce-plan:
	terraform -chdir=$(TF_DIR) plan

gce-apply:
	terraform -chdir=$(TF_DIR) apply

gce-put-key:
	@if [[ -z "$${CURSOR_API_KEY:-}" ]]; then read -rsp "Cursor service account API key: " CURSOR_API_KEY; echo; fi; \
		printf '%s' "$$CURSOR_API_KEY" | gcloud secrets versions add "$(SECRET_ID)" --data-file=-

gce-access:
	@if [[ -z "$(ADMIN_MEMBER)" ]]; then echo "Set ADMIN_MEMBER, for example user:you@example.com"; exit 1; fi
	gcloud projects add-iam-policy-binding "$(PROJECT_ID)" --member "$(ADMIN_MEMBER)" \
		--role roles/iap.tunnelResourceAccessor --condition None
	gcloud projects add-iam-policy-binding "$(PROJECT_ID)" --member "$(ADMIN_MEMBER)" \
		--role roles/compute.osAdminLogin --condition None
	gcloud iam service-accounts add-iam-policy-binding \
		"$(GCE_NAME)-sa@$(PROJECT_ID).iam.gserviceaccount.com" \
		--member "$(ADMIN_MEMBER)" --role roles/iam.serviceAccountUser

gce-logs:
	gcloud compute instances get-serial-port-output "$(GCE_NAME)" --zone "$(ZONE)" | grep startup-script

gce-ssh:
	gcloud compute ssh "$(GCE_NAME)" --zone "$(ZONE)" --tunnel-through-iap

gce-rerun:
	gcloud compute ssh "$(GCE_NAME)" --zone "$(ZONE)" --tunnel-through-iap \
		--command "sudo google_metadata_script_runner startup"

gce-destroy:
	terraform -chdir=$(TF_DIR) destroy

gke-network:
	./gke/scripts/create-network.sh

gke-cluster:
	./gke/scripts/create-cluster.sh

gke-key:
	./gke/scripts/store-api-key.sh

gke-pool:
	./gke/scripts/register-pool.sh

gke-install:
	./gke/scripts/install.sh

gke-render:
	@./gke/scripts/render.sh

gke-status:
	kubectl -n "$${K8S_NAMESPACE:-cursord}" get deploy,pods -l "app.kubernetes.io/instance=$${HELM_RELEASE:-gke-workers}"

gke-destroy:
	./gke/scripts/teardown.sh
