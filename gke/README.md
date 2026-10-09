# GKE + Helm Guide

Use this README for the architecture, operating model, validation, and troubleshooting. Use [`helm/README.md`](helm/README.md) for step-by-step setup commands.

## When To Use GKE

Use GKE for concurrent sessions, warm workers, and many repositories. Each agent request gets its own one-shot worker Pod.

Use [Compute Engine](../gce/README.md) instead for a single-worker demo.

## What Gets Created

The scripts create:

- One VPC and subnet with Private Google Access, plus Cloud NAT on a static egress IP.
- One Artifact Registry repository for the worker image.
- One node service account with `roles/container.defaultNodeServiceAccount` ([node service accounts](https://docs.cloud.google.com/kubernetes-engine/security/configure-node-service-accounts)) and read access to the image.
- One zonal GKE Standard cluster with private nodes, Workload Identity, Shielded Nodes, and node autoscaling.
- One Secret Manager secret, copied into a Kubernetes Secret in the `cursord` namespace.

Cursor's [`anysphere/k8s-workers`](https://github.com/anysphere/k8s-workers) chart (0.2.2) installs a controller Deployment, a spawn-hook ConfigMap, and the controller's ServiceAccount and RBAC.

## Architecture

The chart runs [`agent worker controller --spawn`](https://cursor.com/docs/cloud-agent/self-hosted/pool#worker-controller) as one replica. The controller creates worker Pods with `restartPolicy: Never` in one of two modes:

- **Warm** (`controller.warmIdle: 1`, the default here): keeps one idle worker connected and backfills after each claim.
- **Claim** (`controller.warmIdle: 0`): claims each pending request, then spawns a Pod for it.

Workers serve the any-repo pool `gke-workers`. Worker Pods start `agent` directly, so `docker/entrypoint.sh` is not used and `/workspace` starts empty.

## Optional Overlays

| Overlay | Effect | Needs |
| --- | --- | --- |
| [`values-clone-git-repos.yaml`](helm/values-clone-git-repos.yaml) | Each worker [checks out the requested repositories](https://cursor.com/docs/cloud-agent/self-hosted/pool#any-repo-pools) on claim | A team admin enables GitHub token minting for Team Pool workers |
| [`values-session-token.yaml`](helm/values-session-token.yaml) | Only the controller holds the API key. Each worker gets a [session token](https://cursor.com/docs/cloud-agent/self-hosted/pool#session-tokens) for its claim. Claim mode only. | Cursor enables private-worker session tokens for your team |

Without `--clone-git-repos`, give workers Git credentials and clone in the session or in a [`sessionStart` hook](https://cursor.com/docs/cloud-agent/self-hosted/pool#hooks).

## Network And Security Model

- Nodes have no external IPs, and workers need no inbound access.
- Egress leaves through Cloud NAT on one static IP you can allowlist.
- The node service account has only the default node role and image read access.
- By default each worker Pod gets the service account key as `CURSOR_API_KEY`. The session-token overlay removes it.

## Operating Model

Run one controller per pool. Finished worker Pods stay until you delete them. The install script always applies `values.yaml` plus the overlays listed in `VALUES_OVERLAYS`, so rerun it after any change.

## Validation

A healthy deployment has:

- One running controller Pod.
- In warm mode, one idle worker Pod.
- The `gke-workers` pool listed under **Any repo** in [cursor.com/agents](https://cursor.com/agents).
- During a run, the warm Pod turns busy (or a new Pod appears in claim mode) and the controller spawns a replacement.

## Troubleshooting

### API Key Is Invalid

Pool workers require a Cursor [service account](https://cursor.com/docs/account/enterprise/service-accounts) API key. Other key types are rejected.

### Worker Pods Show `ImagePullBackOff`

Check `IMAGE_NAME` and `TAG`. The node service account needs Artifact Registry Reader on the repository.

### Controller Fails With `kubectl not found`

The controller image needs `agent` and `kubectl`. The shared [`Dockerfile`](../docker/Dockerfile) includes both.

### Controller Errors Mention `workerReadyTimeoutSeconds`

The CLI in the image is older than the chart expects. Rebuild the image.

### Pool Is Missing From The Picker

Register the pool and look under **Any repo**. `GKE_POOL` must match exactly.

### Worker Pods Are `Pending`

Raise the node pool's autoscaling maximum or lower `resources.requests` in `values.yaml`.

### Controller Exits: Session Tokens Not Enabled

Ask Cursor to enable private-worker session tokens, or drop the session-token overlay.

### `get-credentials` Fails With An Auth Plugin Error

Install [`gke-gcloud-auth-plugin`](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#install_plugin).

## Cleanup

Delete the resources when the demo is done. The implementation guide has the command.
