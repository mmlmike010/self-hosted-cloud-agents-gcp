SHELL := /bin/bash

-include .env
export

PROJECT_ID ?= PROJECT_ID
REGION ?= us-east4
ZONE ?= us-east4-a
AR_REPO ?= cursor-workers
SECRET_ID ?= cursor-worker-api-key
TAG ?= v1
WORKER_PLATFORM ?= linux/amd64
IMAGE_REPO ?= $(REGION)-docker.pkg.dev/$(PROJECT_ID)/$(AR_REPO)/cursor-self-hosted-worker
IMAGE ?= $(IMAGE_REPO):$(TAG)
WORKER_IMAGE ?= cursor-self-hosted-worker:local

WORKER_REPOSITORY_URL ?= https://github.com/OWNER/REPO.git
GIT_TOKEN_SECRET_ID ?=
GCE_INSTANCE_NAME ?= cursor-worker-lab

GKE_CLUSTER ?= cursor-workers
K8S_NAMESPACE ?= cursord
HELM_RELEASE ?= gke-workers

GCE_TERRAFORM_VARS := \
	-var "project_id=$(PROJECT_ID)" \
	-var "region=$(REGION)" \
	-var "zone=$(ZONE)" \
	-var "worker_image_tag=$(TAG)" \
	-var "artifact_repository=$(AR_REPO)" \
	-var "secret_id=$(SECRET_ID)" \
	-var "worker_repository_url=$(WORKER_REPOSITORY_URL)" \
	-var "git_token_secret_id=$(GIT_TOKEN_SECRET_ID)"

.PHONY: help check docker-build docker-run ar-login image-push \
	gce-init gce-plan gce-apply gce-destroy gce-put-api-key-secret gce-serial-log gce-rerun-startup \
	gke-credentials gke-create-api-key-secret gke-register-pool gke-install gke-render gke-status gke-uninstall

help:
	@echo "Targets:"
	@echo "  check                       Run offline checks (terraform, shellcheck, hadolint, helm, mermaid)"
	@echo "  docker-build                Build the worker image locally"
	@echo "  docker-run                  Run one worker locally with Docker"
	@echo "  ar-login                    Configure Docker auth for Artifact Registry"
	@echo "  image-push                  Build and push the worker image to Artifact Registry"
	@echo "  gce-init                    terraform init for Path A"
	@echo "  gce-plan                    terraform plan for Path A"
	@echo "  gce-apply                   terraform apply for Path A"
	@echo "  gce-destroy                 terraform destroy for Path A"
	@echo "  gce-put-api-key-secret      Add CURSOR_API_KEY as a new Secret Manager version"
	@echo "  gce-serial-log              Show startup script output from the serial console"
	@echo "  gce-rerun-startup           Rerun the VM startup script over IAP"
	@echo "  gke-credentials             Fetch kubeconfig for the GKE cluster"
	@echo "  gke-create-api-key-secret   Create or refresh the Kubernetes Secret from Secret Manager"
	@echo "  gke-register-pool           Register the gke-workers pool with Cursor"
	@echo "  gke-install                 helm upgrade --install the k8s-workers chart"
	@echo "  gke-render                  helm template the chart with gke/helm/values.yaml"
	@echo "  gke-status                  Show controller and worker Pods"
	@echo "  gke-uninstall               helm uninstall the release"

check:
	./scripts/check.sh

docker-build:
	docker build -f docker/Dockerfile.gcp -t "$(WORKER_IMAGE)" .

docker-run:
	docker run --rm \
		--env CURSOR_API_KEY \
		--env CURSOR_WORKER_POOL_NAME \
		--env CURSOR_WORKER_IDLE_RELEASE_TIMEOUT \
		--env WORKER_REPOSITORY_URL \
		"$(WORKER_IMAGE)"

ar-login:
	gcloud auth configure-docker "$(REGION)-docker.pkg.dev"

image-push:
	docker buildx build --platform "$(WORKER_PLATFORM)" -f docker/Dockerfile.gcp \
		-t "$(IMAGE)" --push .

gce-init:
	terraform -chdir=gce/terraform init

gce-plan:
	terraform -chdir=gce/terraform plan $(GCE_TERRAFORM_VARS)

gce-apply:
	terraform -chdir=gce/terraform apply $(GCE_TERRAFORM_VARS)

gce-destroy:
	terraform -chdir=gce/terraform destroy $(GCE_TERRAFORM_VARS)

gce-put-api-key-secret:
	@if [[ -z "$${CURSOR_API_KEY:-}" ]]; then echo "CURSOR_API_KEY must be set in .env or the shell."; exit 1; fi
	@printf '%s' "$${CURSOR_API_KEY}" | gcloud secrets versions add "$(SECRET_ID)" --data-file=-

gce-serial-log:
	gcloud compute instances get-serial-port-output "$(GCE_INSTANCE_NAME)" --zone "$(ZONE)" \
		| grep startup-script

gce-rerun-startup:
	gcloud compute ssh "$(GCE_INSTANCE_NAME)" --zone "$(ZONE)" --tunnel-through-iap \
		--command "sudo google_metadata_script_runner startup"

gke-credentials:
	gcloud container clusters get-credentials "$(GKE_CLUSTER)" --location "$(ZONE)"

gke-create-api-key-secret:
	./gke/helm/scripts/create-api-key-secret.sh

gke-register-pool:
	@./gke/helm/scripts/register-pool.sh

gke-install:
	./gke/helm/scripts/install-controller.sh

gke-render:
	@./gke/helm/scripts/render.sh

gke-status:
	kubectl -n "$(K8S_NAMESPACE)" get deploy,pods -l app.kubernetes.io/instance=$(HELM_RELEASE)

gke-uninstall:
	helm uninstall "$(HELM_RELEASE)" -n "$(K8S_NAMESPACE)"
