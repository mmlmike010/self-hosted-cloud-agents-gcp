# GKE Implementation Guide

This is the setup runbook for the GKE + Helm path. For architecture and troubleshooting, see [`../README.md`](../README.md).

Run all commands from the repository root. The `make gke-*` targets run the scripts in [`../scripts/`](../scripts/) that reads `.env`.

## 1. Confirm Prerequisites

- Cursor Enterprise, with **Allow Self-Hosted Machines** turned on by a team admin ([requirements](https://cursor.com/docs/cloud-agent/self-hosted#requirements)).
- A Cursor [service account API key](https://cursor.com/docs/account/enterprise/service-accounts#managing-api-keys).
- A GCP project with billing, and permission to create Compute Engine networking, Artifact Registry, Secret Manager, IAM, and GKE resources.
- gcloud with `gke-gcloud-auth-plugin`, kubectl, Helm 3.8 or later, Docker with buildx, and GNU Make.

## 2. Configure `.env`

```bash
cp .env.example .env
```

Fill in at least:

```bash
PROJECT_ID=PROJECT_ID
REGION=us-east4
ZONE=us-east4-a
```

Keep the API key out of `.env`. Export it for this shell instead:

```bash
read -rs CURSOR_API_KEY && export CURSOR_API_KEY
```

## 3. Authenticate And Enable APIs

```bash
gcloud auth login
gcloud config set project PROJECT_ID
make apis
```

## 4. Create The Network

```bash
make gke-network
```

This prints the static egress IP to allowlist.

## 5. Create The Registry And Push The Image

```bash
make registry
make image
```

## 6. Create The Cluster

```bash
make gke-cluster
```

This creates the node service account and a private zonal cluster, then runs `kubectl get nodes`.

## 7. Store The API Key

```bash
make gke-key
```

This adds the key to Secret Manager and creates the `cursor-workers-api-key` Secret in the `cursord` namespace.

## 8. Register The Pool

```bash
make gke-pool
```

[Registering the pool](https://cursor.com/docs/cloud-agent/api/endpoints#register-a-pool) keeps `gke-workers` in the **Any repo** picker even with zero workers.

## 9. Install The Chart

```bash
make gke-install
```

This installs `k8s-workers` 0.2.2 from its [GitHub release](https://github.com/anysphere/k8s-workers/releases/tag/v0.2.2) with [`values.yaml`](values.yaml). Run `make gke-render` to print the manifests without installing.

To add an overlay, list it in `.env` and rerun the install:

```bash
VALUES_OVERLAYS=values-clone-git-repos.yaml
```

## 10. Validate The Workers

```bash
make gke-status
kubectl -n cursord logs -l app.kubernetes.io/component=controller -f
kubectl -n cursord logs -l app.kubernetes.io/component=worker --tail 100
make pools
```

Open [cursor.com/agents](https://cursor.com/agents), choose **Any repo** and the `gke-workers` pool, and run a prompt such as "list the top-level files".

## 11. Update Or Rotate

New image: set a new `TAG` in `.env`, then:

```bash
make image
make gke-install
```

New key: add a version, refresh the Secret, and restart the controller.

```bash
./gke/scripts/store-api-key.sh --new-version
kubectl -n cursord rollout restart deployment -l app.kubernetes.io/instance=gke-workers
```

Delete finished worker Pods:

```bash
kubectl -n cursord delete pod -l app.kubernetes.io/component=worker --field-selector=status.phase=Succeeded
```

## 12. Clean Up

```bash
make gke-destroy
```

gcloud asks before each delete. If the Compute Engine path uses the same project, run `KEEP_SHARED=1 make gke-destroy` to keep the shared registry and secret.
