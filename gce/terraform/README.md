# Compute Engine Implementation Guide

This is the implementation runbook for the Compute Engine + Docker path (Path A).

For the architecture, operating model, validation expectations, and troubleshooting guide, see [`../README.md`](../README.md).

Run all commands from the repository root. Each step lists the matching `make` shortcut when there is one. The Makefile reads the same variable names from `.env` or your shell (see [`.env.example`](../../.env.example)).

## 1. Confirm Prerequisites

Confirm the [Cursor, Google Cloud, and tool prerequisites](../../README.md#prerequisites), and that egress to the [required hosts](../../README.md#required-egress) is allowed.

## 2. Set Variables And Enable APIs

```bash
export PROJECT_ID="PROJECT_ID"
export REGION="REGION"            # for example us-east4
export ZONE="ZONE"                # for example us-east4-a
export AR_REPO=cursor-workers
export SECRET_ID=cursor-worker-api-key
export TAG=v1
export IMAGE_REPO="$REGION-docker.pkg.dev/$PROJECT_ID/$AR_REPO/cursor-self-hosted-worker"
export IMAGE="$IMAGE_REPO:$TAG"

# Paste the Cursor service account API key without it landing in shell history
read -rs CURSOR_API_KEY && export CURSOR_API_KEY

gcloud auth login
gcloud config set project "$PROJECT_ID"
gcloud services enable compute.googleapis.com artifactregistry.googleapis.com \
  secretmanager.googleapis.com iap.googleapis.com container.googleapis.com
```

## 3. Give The Worker A Checkout (Recommended)

Cursor's docs state that a repo-backed pool worker uses the checkouts it already has and does not clone. The AWS lab only runs `git init` with an origin, which gives the agent a workspace with no files.

To give the worker real code, store a read-only Git token (for GitHub, a fine-grained token with **Contents: read** on the repo) in Secret Manager. On first boot the startup script clones the repository with it. The token is passed as a one-off header and is not written to `.git/config`.

```bash
gcloud secrets create cursor-git-read-token --replication-policy automatic
read -rs GIT_READ_TOKEN && printf '%s' "$GIT_READ_TOKEN" \
  | gcloud secrets versions add cursor-git-read-token --data-file=-
unset GIT_READ_TOKEN
```

Skip this step only if you plan to populate `/opt/cursor/worker` yourself. See [Open Items To Confirm](../../README.md#open-items-to-confirm).

## 4. Apply Infrastructure

Review the plan before you confirm. The VM can boot before the API key or image exists. The startup script retries each for about 10 minutes.

```bash
gcloud auth application-default login   # credentials for Terraform
export GIT_TOKEN_SECRET_ID=cursor-git-read-token   # set to "" if you skipped step 3

terraform -chdir=gce/terraform init
terraform -chdir=gce/terraform apply \
  -var "project_id=$PROJECT_ID" \
  -var "region=$REGION" -var "zone=$ZONE" \
  -var "worker_image_tag=$TAG" \
  -var "worker_repository_url=https://github.com/OWNER/REPO.git" \
  -var "git_token_secret_id=$GIT_TOKEN_SECRET_ID"
```

Make shortcut: `make gce-init gce-apply` (uses `WORKER_REPOSITORY_URL` and `GIT_TOKEN_SECRET_ID`).

Confirm the plan creates only the expected resources: VPC, subnet, router, NAT and its static IP, IAP SSH firewall rule, Artifact Registry repository, Secret Manager secret container, service account and its IAM bindings, and the VM.

Note the static egress IP for allowlists:

```bash
terraform -chdir=gce/terraform output nat_egress_ip
```

## 5. Upload The Cursor Service Account Key

```bash
printf '%s' "$CURSOR_API_KEY" | gcloud secrets versions add "$SECRET_ID" --data-file=-
```

Make shortcut: `make gce-put-api-key-secret`.

## 6. Build And Push The Worker Image

Use `linux/amd64` for E2 and N2 machine types, or `linux/arm64` for Arm types such as T2A and C4A (and change the boot image to an Arm image).

```bash
gcloud auth configure-docker "$REGION-docker.pkg.dev"
docker buildx build --platform linux/amd64 -f docker/Dockerfile.gcp \
  -t "$IMAGE" --push .
```

Make shortcut: `make ar-login image-push`.

## 7. Grant SSH Access Through IAP

OS Login with sudo needs IAP-secured Tunnel User, Compute OS Admin Login, and Service Account User on the VM's service account.

```bash
export ADMIN=user:YOUR_EMAIL
export VM_SA="cursor-worker-lab-sa@$PROJECT_ID.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "$ADMIN" \
  --role roles/iap.tunnelResourceAccessor
gcloud projects add-iam-policy-binding "$PROJECT_ID" --member "$ADMIN" \
  --role roles/compute.osAdminLogin
gcloud iam service-accounts add-iam-policy-binding "$VM_SA" --member "$ADMIN" \
  --role roles/iam.serviceAccountUser
```

## 8. Validate The Worker

```bash
# Startup script output from the serial console (no SSH needed)
gcloud compute instances get-serial-port-output cursor-worker-lab --zone "$ZONE" \
  | grep startup-script

# Or connect through IAP
gcloud compute ssh cursor-worker-lab --zone "$ZONE" --tunnel-through-iap
# then, on the VM:
sudo tail -n 100 /var/log/cursor-worker-bootstrap.log
sudo docker logs -f cursor-worker
```

Make shortcut: `make gce-serial-log`.

Then confirm an agent picks up a job:

1. Check connected and in-use worker counts from the Cursor side:

   ```bash
   curl -s -u "$CURSOR_API_KEY:" \
     "https://api.cursor.com/v0/private-workers/pools?scope=team_pool"
   ```

2. Open [cursor.com/agents](https://cursor.com/agents), pick the repository that matches `worker_repository_url`, choose pool `gce-lab`, and run a small prompt such as "list the top-level files".
3. Confirm `inUseWorkerCount` rises to 1 while the agent runs, and that the agent sees your repository files.

## 9. If The Bootstrap Timed Out

Add the missing secret version or image, then rerun the startup script in place. No VM replacement is needed.

```bash
gcloud compute ssh cursor-worker-lab --zone "$ZONE" --tunnel-through-iap \
  --command "sudo google_metadata_script_runner startup"
```

Make shortcut: `make gce-rerun-startup`.

## 10. Rotate The Key Or Update The Image

Add a new secret version, then rerun the startup script. It always recreates the container, so the new key takes effect.

```bash
# Rotate the key: add a new secret version, then rerun the startup script
read -rs NEW_KEY && printf '%s' "$NEW_KEY" \
  | gcloud secrets versions add "$SECRET_ID" --data-file=-
unset NEW_KEY
gcloud compute ssh cursor-worker-lab --zone "$ZONE" --tunnel-through-iap \
  --command "sudo google_metadata_script_runner startup"
```

For a new image pushed with the same tag, push it (step 6) and rerun the startup script the same way. Changing `worker_image_tag` in Terraform instead replaces the VM and its boot disk, including `/opt/cursor/worker`.

## 11. Clean Up

```bash
terraform -chdir=gce/terraform destroy \
  -var "project_id=$PROJECT_ID" -var "region=$REGION" -var "zone=$ZONE" \
  -var "worker_repository_url=https://github.com/OWNER/REPO.git" \
  -var "git_token_secret_id=$GIT_TOKEN_SECRET_ID"
gcloud secrets delete cursor-git-read-token   # only if you created it in step 3
```

Make shortcut: `make gce-destroy`.

## Safety Notes

- Do not put real service account API keys or Git tokens in Terraform variables or state.
- Do not commit `.env`, Terraform state, or GCP credentials.
- Rotate the service account key if it is exposed in logs, shell history, or the serial console.
