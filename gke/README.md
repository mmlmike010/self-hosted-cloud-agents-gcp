# Path B: GKE Standard + k8s-workers Helm chart

A private GKE Standard cluster runs Cursor's [`anysphere/k8s-workers`](https://github.com/anysphere/k8s-workers) chart (0.2.2). The chart runs `agent worker controller --spawn` as a single-replica Deployment. The [worker controller](https://cursor.com/docs/cloud-agent/self-hosted/pool#worker-controller) creates one-shot worker Pods (`restartPolicy: Never`) in one of two modes:

- **Warm (`controller.warmIdle: 1`, this lab's default):** keeps one idle worker connected and backfills after each claim.
- **Claim (`controller.warmIdle: 0`):** claims each pending request, then spawns a Pod for it.

Workers serve the any-repo pool `gke-workers`. Worker Pods start `agent` directly, so [`docker/entrypoint.sh`](../docker/entrypoint.sh) is not used and `/workspace` starts empty with no git remote.

## Files

| File | Purpose |
| --- | --- |
| [`values.yaml`](values.yaml) | Chart values: pool, warm idle count, labels, Pod resources |
| [`values-clone-git-repos.yaml`](values-clone-git-repos.yaml) | Overlay: each worker checks out the requested repositories on claim |
| [`values-session-token.yaml`](values-session-token.yaml) | Overlay: only the controller holds the API key |
| [`scripts/`](scripts/) | `gcloud`, `kubectl`, and `helm` steps, idempotent and driven by `.env` |

## Steps

Run everything from the repository root with `.env` filled in (see the [top-level README](../README.md#quick-start)).

### 1. Network with Cloud NAT

Custom VPC, subnet `10.20.0.0/20` with Private Google Access, and Cloud NAT on one static IP. `--nat-all-subnet-ip-ranges` also covers the Pod and Service ranges. Prints the egress IP to allowlist.

```bash
make apis
make gke-network
```

### 2. Artifact Registry and image

```bash
make registry
make image
```

### 3. Node service account and private cluster

A dedicated node service account gets `roles/container.defaultNodeServiceAccount` ([GKE node service accounts](https://docs.cloud.google.com/kubernetes-engine/security/configure-node-service-accounts)) plus Artifact Registry Reader on the repository. The cluster is zonal, with private nodes, Workload Identity, Shielded Nodes with Secure Boot, and autoscaling from `GKE_MIN_NODES` to `GKE_MAX_NODES` (per zone).

```bash
make gke-cluster
```

For production, use a regional `--location` and restrict the control plane with `--enable-master-authorized-networks --master-authorized-networks CIDR` in [`scripts/create-cluster.sh`](scripts/create-cluster.sh).

### 4. Store the API key

Secret Manager is the source of truth. The script creates the `cursord` namespace and a Kubernetes Secret from it over stdin, so the key never appears in command arguments. Create the key under a Cursor [service account](https://cursor.com/docs/account/enterprise/service-accounts#managing-api-keys).

```bash
make gke-key                             # prompts for the key on first run
```

### 5. Register the pool

[Registering the pool](https://cursor.com/docs/cloud-agent/api/endpoints#register-a-pool) keeps it in the **Any repo** picker even with zero connected workers.

```bash
make gke-pool
```

### 6. Install the chart

Installs the chart straight from its [GitHub release](https://github.com/anysphere/k8s-workers/releases/tag/v0.2.2). `make gke-render` prints the manifests without touching the cluster.

```bash
make gke-install
```

Size `resources` in `values.yaml` like a CI runner for your repositories.

### 7. Optional overlays

List overlays in `VALUES_OVERLAYS` in `.env` (space-separated), then rerun `make gke-install`. The scripts always apply `values.yaml` plus the overlays, so no `--reuse-values` drift.

| Overlay | What it does | Needs |
| --- | --- | --- |
| `values-clone-git-repos.yaml` | Adds `--clone-git-repos`: each worker [checks out every requested repository](https://cursor.com/docs/cloud-agent/self-hosted/pool#any-repo-pools) at the requested branch or commit, using a minted short-lived GitHub token | A team admin enables GitHub token minting for Team Pool workers. HTTPS GitHub remotes. |
| `values-session-token.yaml` | Only the controller holds the API key. Each worker Pod reads a [session token](https://cursor.com/docs/cloud-agent/self-hosted/pool#session-tokens) that serves its single claim. Sets `controller.warmIdle: 0`. | Private-worker session tokens enabled for your team by Cursor. Claim mode only (the chart refuses `warmIdle` above 0). |

Without `--clone-git-repos`, any-repo workers start with an empty `/workspace`. Give the worker Git credentials and clone in the session, or in a [`sessionStart` hook](https://cursor.com/docs/cloud-agent/self-hosted/pool#hooks), which receives the run's repositories.

### 8. Verify

```bash
make gke-status
kubectl -n cursord logs -l app.kubernetes.io/component=controller -f
kubectl -n cursord get pods -l app.kubernetes.io/component=worker
kubectl -n cursord logs -l app.kubernetes.io/component=worker --tail 100
```

Then follow [Verify an agent picks up a job](../README.md#verify-an-agent-picks-up-a-job): choose **Any repo** and the pool `gke-workers`. The warm Pod turns busy (or a new Pod appears in claim mode), and the controller spawns a replacement.

## Day 2

```bash
# New image: set a new TAG in .env, then
make image
make gke-install

# Rotate the key: add a Secret Manager version, refresh the Kubernetes Secret, restart the controller
./gke/scripts/store-api-key.sh --new-version
kubectl -n cursord rollout restart deployment -l app.kubernetes.io/instance=gke-workers

# Finished one-shot worker Pods stay until deleted
kubectl -n cursord delete pod -l app.kubernetes.io/component=worker --field-selector=status.phase=Succeeded
```

Running worker Pods keep the old key in their environment until they exit. Disable the old Secret Manager version once they have cycled.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Invalid API key` or HTTP 401 | Pool workers only accept a service account API key. |
| `ImagePullBackOff` | Check `IMAGE_NAME` and `TAG`. The node service account needs Artifact Registry Reader on the repository. |
| Controller CrashLoop, `kubectl not found` | Build from [`docker/Dockerfile`](../docker/Dockerfile), which includes kubectl, or set `controller.image` to an image with `agent` and `kubectl`. |
| Controller errors mention `workerReadyTimeoutSeconds` | The CLI in the image is older than the chart expects. Rebuild the image to pick up the current CLI. |
| Pool missing from the picker | `make gke-pool`, then look under **Any repo**. `GKE_POOL` must match exactly. |
| Worker Pods `Pending` | Raise `GKE_MAX_NODES` (then update the node pool autoscaling) or lower `resources.requests`. |
| `get-credentials` auth plugin error | Install `gke-gcloud-auth-plugin`. |
| Controller exits: session tokens not enabled | Ask Cursor to enable private-worker session tokens, or drop the session-token overlay. |
| Timeouts reaching Cursor or GitHub | Check Cloud NAT: `gcloud compute routers get-status cursor-workers-router --region REGION`. |

## Teardown

```bash
make gke-destroy
```

gcloud asks before each delete. If Path A uses the same project, keep the shared Artifact Registry repository and secret with `KEEP_SHARED=1 make gke-destroy`.
