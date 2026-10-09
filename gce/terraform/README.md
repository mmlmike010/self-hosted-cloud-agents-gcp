# Compute Engine Implementation Guide

This is the setup runbook for the Compute Engine + Docker path. For architecture and troubleshooting, see [`../README.md`](../README.md).

Run all commands from the repository root.

## 1. Confirm Prerequisites

- Cursor Enterprise, with **Allow Self-Hosted Machines** turned on by a team admin ([requirements](https://cursor.com/docs/cloud-agent/self-hosted#requirements)).
- A Cursor [service account API key](https://cursor.com/docs/account/enterprise/service-accounts#managing-api-keys).
- A GCP project with billing, and permission to create Compute Engine, Artifact Registry, Secret Manager, IAM, and IAP resources.
- gcloud, Terraform 1.6 or later, Docker with buildx, and GNU Make.

## 2. Configure `.env`

```bash
cp .env.example .env
```

Fill in at least:

```bash
PROJECT_ID=PROJECT_ID
REGION=us-east4
ZONE=us-east4-a
WORKER_REPOSITORY_URL=https://github.com/OWNER/REPO.git
```

Keep the API key out of `.env`. Targets that need it prompt for it.

## 3. Authenticate And Enable APIs

```bash
gcloud auth login
gcloud config set project PROJECT_ID
gcloud auth application-default login
make apis
```

## 4. Store A Read-Only Git Token (Optional)

Use a token that can only read the repository, such as a GitHub fine-grained token with **Contents: read**. The VM clones the repository with it on first boot.

```bash
make gce-git-token
```

Then set `GIT_TOKEN_SECRET_ID=cursor-git-read-token` in `.env`.

## 5. Apply Terraform

```bash
make gce-init
make gce-plan
make gce-apply
```

The VM may boot before the key and image exist. The startup script waits up to 10 minutes for each.

## 6. Upload The Service Account Key

```bash
make gce-put-key
```

## 7. Build And Push The Worker Image

```bash
make image
```

The default `PLATFORM=linux/amd64` matches the default `e2-standard-2` machine type.

## 8. Grant IAP SSH Access

```bash
make gce-access ADMIN_MEMBER=user:you@example.com
```

This grants IAP-secured Tunnel User, Compute OS Admin Login, and Service Account User on the VM's service account ([OS Login roles](https://docs.cloud.google.com/compute/docs/oslogin/set-up-oslogin)).

## 9. Validate The Worker

```bash
make gce-logs
make gce-ssh
```

On the VM:

```bash
sudo docker logs -f cursor-worker
sudo docker exec cursor-worker curl -fsS http://127.0.0.1:8080/readyz
```

Back on your machine, check the pool from Cursor's API:

```bash
read -rs CURSOR_API_KEY && export CURSOR_API_KEY
make pools
```

Open [cursor.com/agents](https://cursor.com/agents), pick your repository and the `gce-lab` pool, and run a prompt such as "list the top-level files". `inUseWorkerCount` rises to 1 while it runs.

## 10. Rerun The Startup Script

Rerun it after a timed-out bootstrap, an image push, or a key rotation (`make gce-put-key`):

```bash
make gce-rerun
```

## 11. Clean Up

```bash
make gce-destroy
gcloud secrets delete cursor-git-read-token
```

Skip the second command if you did not create a Git token.
