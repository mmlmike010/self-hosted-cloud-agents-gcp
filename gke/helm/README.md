# GKE Implementation Guide

This is the implementation runbook for the GKE Standard + `k8s-workers` Helm chart path (Path B).

For the architecture, how workers start, validation expectations, and troubleshooting guide, see [`../README.md`](../README.md).

Run all commands from the repository root. Each step lists the matching `make` shortcut when there is one. The Makefile reads the same variable names from `.env` or your shell (see [`.env.example`](../../.env.example)).

Before you start, confirm the [Cursor, Google Cloud, and tool prerequisites](../../README.md#prerequisites) and the [required egress](../../README.md#required-egress).

If you already ran Path A in the same project, its Terraform owns the `cursor-workers` Artifact Registry repository and the `cursor-worker-api-key` secret. Skip the create commands for those in steps 2 and 4, and leave them out of the teardown in step 10.

## 0. Set Variables And Enable APIs

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

## 1. Network With Cloud NAT

Private nodes have no external IPs, so Cloud NAT provides egress. `--nat-all-subnet-ip-ranges` also covers the Pod secondary ranges.

```bash
gcloud compute networks create cursor-workers-vpc --subnet-mode custom
gcloud compute networks subnets create cursor-workers-subnet \
  --network cursor-workers-vpc --region "$REGION" \
  --range 10.20.0.0/20 --enable-private-ip-google-access

gcloud compute routers create cursor-workers-router \
  --network cursor-workers-vpc --region "$REGION"
gcloud compute addresses create cursor-workers-nat-ip --region "$REGION"
gcloud compute routers nats create cursor-workers-nat \
  --router cursor-workers-router --region "$REGION" \
  --nat-all-subnet-ip-ranges --nat-external-ip-pool cursor-workers-nat-ip

# Static egress IP to allowlist on GitHub Enterprise, proxies, internal services
gcloud compute addresses describe cursor-workers-nat-ip --region "$REGION" \
  --format 'value(address)'
```

## 2. Artifact Registry And Image

```bash
gcloud artifacts repositories create "$AR_REPO" \
  --repository-format docker --location "$REGION"

gcloud auth configure-docker "$REGION-docker.pkg.dev"
docker buildx build --platform linux/amd64 -f docker/Dockerfile.gcp \
  -t "$IMAGE" --push .
```

Make shortcut for the build: `make ar-login image-push`.

## 3. Node Service Account And Private Cluster

The node service account gets the minimum GKE node role plus read access to the image. `--num-nodes` and the autoscaling limits are per zone. For production, use a regional `--location` and restrict the control plane with `--enable-master-authorized-networks --master-authorized-networks CIDR`.

```bash
gcloud iam service-accounts create cursor-gke-nodes
export NODE_SA="cursor-gke-nodes@$PROJECT_ID.iam.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member "serviceAccount:$NODE_SA" --role roles/container.defaultNodeServiceAccount
gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" --location "$REGION" \
  --member "serviceAccount:$NODE_SA" --role roles/artifactregistry.reader

gcloud container clusters create cursor-workers \
  --location "$ZONE" \
  --network cursor-workers-vpc --subnetwork cursor-workers-subnet \
  --enable-ip-alias --enable-private-nodes \
  --service-account "$NODE_SA" \
  --workload-pool "$PROJECT_ID.svc.id.goog" \
  --enable-shielded-nodes --shielded-secure-boot \
  --machine-type e2-standard-4 --num-nodes 2 \
  --enable-autoscaling --min-nodes 1 --max-nodes 5

gcloud container clusters get-credentials cursor-workers --location "$ZONE"
kubectl get nodes
```

Make shortcut for credentials: `make gke-credentials`.

## 4. Store The Key

Secret Manager is the source of truth. The Kubernetes Secret is created from it without the key appearing in command arguments.

```bash
gcloud secrets create "$SECRET_ID" --replication-policy automatic
printf '%s' "$CURSOR_API_KEY" | gcloud secrets versions add "$SECRET_ID" --data-file=-

kubectl create namespace cursord
gcloud secrets versions access latest --secret "$SECRET_ID" \
  | kubectl -n cursord create secret generic cursor-workers-api-key \
      --from-file=api-key=/dev/stdin
```

Make shortcut for the Kubernetes part: `make gke-create-api-key-secret` ([`scripts/create-api-key-secret.sh`](scripts/create-api-key-secret.sh) creates the namespace if needed and is safe to rerun).

## 5. Register The Pool

Registering the name keeps the pool in the **Any repo** picker even with zero connected workers. The controller also registers non-default pool names when it starts.

```bash
curl --request POST \
  --url "https://api.cursor.com/v0/private-workers/pools" \
  -u "$CURSOR_API_KEY:" \
  --header 'Content-Type: application/json' \
  --data '{"scope":"team","poolName":"gke-workers"}'
```

Make shortcut: `make gke-register-pool`.

## 6. Install The Worker Controller

`warmIdle=1` keeps one idle worker connected, and the controller backfills after each claim. `warmIdle=0` spawns only on demand. Size worker requests like a CI runner for your repos.

[`values.yaml`](values.yaml) holds the pool, `warmIdle`, Secret name, and worker resources. The image is passed on the command line because it contains `PROJECT_ID`.

```bash
helm upgrade --install gke-workers oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers \
  --version 0.2.2 \
  --namespace cursord \
  --values gke/helm/values.yaml \
  --set image.repository="$IMAGE_REPO" \
  --set image.tag="$TAG"
```

Make shortcut: `make gke-install`. To review the rendered manifests first: `make gke-render`.

`values.yaml` renders identically to these flags, if you prefer not to use the file:

```bash
helm upgrade --install gke-workers oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers \
  --version 0.2.2 \
  --namespace cursord \
  --set image.repository="$IMAGE_REPO" \
  --set image.tag="$TAG" \
  --set pool=gke-workers \
  --set controller.warmIdle=1 \
  --set auth.existingSecret=cursor-workers-api-key \
  --set resources.requests.cpu=1 \
  --set resources.requests.memory=2Gi \
  --set resources.limits.memory=4Gi
```

### Optional: Clone Repositories On Claim

Any-repo workers start with an empty `/workspace`. To have each worker check out the requested repositories on claim, add `--clone-git-repos`. A team admin must enable GitHub token minting for Team Pool workers, and remotes must be HTTPS GitHub URLs. Otherwise give the worker Git credentials and clone in the session or a `sessionStart` hook.

```bash
helm upgrade gke-workers oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers \
  --version 0.2.2 --namespace cursord --reuse-values \
  --set 'extraArgs[0]=--clone-git-repos'
```

## 7. Optional: Keep The API Key Out Of Worker Pods

By default every worker Pod receives the service account key as `CURSOR_API_KEY`. With session tokens only the controller holds the key, and each worker gets a token for its single claim. Claim mode only (the chart refuses `warmIdle` above 0 with session tokens), and private-worker session tokens must be enabled for your team by Cursor.

```bash
helm upgrade gke-workers oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers \
  --version 0.2.2 --namespace cursord --reuse-values \
  --set controller.warmIdle=0 --set auth.sessionToken=true
```

## 8. Verify

```bash
kubectl -n cursord get deploy,pods -l app.kubernetes.io/instance=gke-workers
kubectl -n cursord logs -l app.kubernetes.io/component=controller -f
kubectl -n cursord get pods -l app.kubernetes.io/component=worker
kubectl -n cursord logs -l app.kubernetes.io/component=worker --tail 100
```

Make shortcut for the first command: `make gke-status`.

Then confirm an agent picks up a job:

1. Check connected and in-use worker counts from the Cursor side:

   ```bash
   curl -s -u "$CURSOR_API_KEY:" \
     "https://api.cursor.com/v0/private-workers/pools?scope=team_pool"
   ```

2. Open [cursor.com/agents](https://cursor.com/agents), choose **Any repo** and pool `gke-workers`, and run a small prompt such as "list the top-level files".
3. Confirm `inUseWorkerCount` rises to 1 while the agent runs. The warm Pod turns busy (or a new Pod appears in claim mode) and the controller spawns a replacement.

## 9. Day 2 Operations

```bash
# New image: push a new TAG, then
helm upgrade gke-workers oci://public.ecr.aws/k0i0n2g5/charts/k8s-workers \
  --version 0.2.2 --namespace cursord --reuse-values --set image.tag=NEW_TAG

# Rotate the key: add a Secret Manager version, refresh the Kubernetes Secret,
# then restart the controller
gcloud secrets versions access latest --secret "$SECRET_ID" \
  | kubectl -n cursord create secret generic cursor-workers-api-key \
      --from-file=api-key=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply -f -
kubectl -n cursord rollout restart deployment \
  -l app.kubernetes.io/instance=gke-workers

# Finished one-shot worker Pods stay until deleted
kubectl -n cursord delete pod -l app.kubernetes.io/component=worker \
  --field-selector=status.phase=Succeeded
```

`make gke-create-api-key-secret` runs the same Secret refresh.

## 10. Teardown

```bash
helm uninstall gke-workers -n cursord
kubectl delete namespace cursord
gcloud container clusters delete cursor-workers --location "$ZONE"
gcloud artifacts repositories delete "$AR_REPO" --location "$REGION"
gcloud secrets delete "$SECRET_ID"
gcloud iam service-accounts delete "cursor-gke-nodes@$PROJECT_ID.iam.gserviceaccount.com"
gcloud compute routers nats delete cursor-workers-nat \
  --router cursor-workers-router --region "$REGION"
gcloud compute routers delete cursor-workers-router --region "$REGION"
gcloud compute addresses delete cursor-workers-nat-ip --region "$REGION"
gcloud compute networks subnets delete cursor-workers-subnet --region "$REGION"
gcloud compute networks delete cursor-workers-vpc
```

Make shortcut for the first command: `make gke-uninstall`.

## Safety Notes

- Do not put the service account key in `values.yaml` or `--set auth.apiKey`. Use `auth.existingSecret` as above.
- Do not commit `.env`, kubeconfig files, or GCP credentials.
- Rotate the service account key if it is exposed in logs or shell history.
