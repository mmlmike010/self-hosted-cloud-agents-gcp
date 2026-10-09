# GKE + Helm Guide

Use this README to understand the GKE architecture, operating model, validation expectations, and troubleshooting paths. Use [`helm/README.md`](helm/README.md) for the step-by-step setup runbook.

## When To Use GKE

The GKE path fits teams that need concurrent Cloud Agent sessions across many repos. Each claimed request gets its own worker Pod, or the controller keeps a fixed number of idle workers warm.

It replaces both the EKS and ECS/Fargate paths of the AWS lab. Use [Compute Engine](../gce/README.md) instead for a single repo-bound worker with the smallest footprint.

## Documentation Map

- This README: architecture, how workers start, security model, operations, validation, and troubleshooting.
- [`helm/README.md`](helm/README.md): network, image, cluster, key, pool registration, chart install, optional variants, day 2 operations, and teardown.
- [`helm/values.yaml`](helm/values.yaml): the chart values used by the runbook.
- [`helm/scripts/`](helm/scripts/): helpers behind the `make gke-*` targets.

## What Gets Created

- A custom VPC `cursor-workers-vpc` and subnet `cursor-workers-subnet` (`10.20.0.0/20`) with Private Google Access.
- A Cloud Router and Cloud NAT using one static external IP `cursor-workers-nat-ip`.
- An Artifact Registry Docker repository for the worker image.
- A node service account `cursor-gke-nodes` with the minimum GKE node role (`roles/container.defaultNodeServiceAccount`) and Artifact Registry Reader on the repository.
- A zonal GKE Standard cluster `cursor-workers` with private nodes, Workload Identity Federation for GKE (`--workload-pool`), Shielded Nodes with Secure Boot, and `e2-standard-4` nodes autoscaling from 1 to 5 per zone.
- A Secret Manager secret with the Cursor service account key, copied into the Kubernetes Secret `cursor-workers-api-key` in namespace `cursord`.
- A Helm release `gke-workers` of Cursor's `anysphere/k8s-workers` chart, version 0.2.2.

## Architecture

The chart runs `agent worker controller` as a single-replica Deployment. Two modes:

- **Claim mode** (`controller.warmIdle=0`): the controller claims each pending request and creates a one-shot worker Pod for it.
- **Warm idle** (`controller.warmIdle=N`): the controller keeps N idle workers connected and backfills after each claim. [`helm/values.yaml`](helm/values.yaml) sets `warmIdle: 1`.

Worker Pods are created by the controller's spawn hook with `kubectl` (so the controller image needs `kubectl`, which [`docker/Dockerfile.gcp`](../docker/Dockerfile.gcp) adds). They use `restartPolicy: Never`, so a worker that exits after its idle release timeout stays `Succeeded` until deleted.

These workers serve an any-repo pool named `gke-workers`.

## How Workers Start

Worker Pods start `agent` directly (the chart sets `command: [agent]`), so `docker/entrypoint.sh` is not used and `/workspace` has no git remote.

Any-repo workers start with an empty `/workspace`. To have each worker check out the requested repositories on claim, add `--clone-git-repos` (see [`helm/README.md`](helm/README.md), step 6). A team admin must enable GitHub token minting for Team Pool workers, and remotes must be HTTPS GitHub URLs. Otherwise give the worker Git credentials and clone in the session or a `sessionStart` hook.

By default every worker Pod receives the service account key as `CURSOR_API_KEY`. With session tokens (step 7) only the controller holds the key, and each worker gets a token for its single claim.

## Network And Security Model

- Workers connect outbound to Cursor over HTTPS. Cursor never connects in.
- Nodes are private, with no external IPs. Cloud NAT provides egress; `--nat-all-subnet-ip-ranges` also covers the Pod secondary ranges.
- The node service account has only the GKE node role and read access to the image.
- Secret Manager is the source of truth for the key. The Kubernetes Secret is created from it without the key appearing in command arguments.
- For production, use a regional `--location` and restrict the control plane with `--enable-master-authorized-networks --master-authorized-networks CIDR`.

## Operating Model

- **Scaling:** `warmIdle=1` keeps one idle worker and backfills after each claim. `warmIdle=0` spawns only on demand. Node autoscaling (1 to 5 per zone) adds capacity for Pending worker Pods.
- **Sizing:** size worker requests like a CI runner for your repos. The values file requests 1 CPU and 2Gi memory, with a 4Gi memory limit.
- **New image:** push a new tag, then `helm upgrade` with `image.tag`.
- **Key rotation:** add a Secret Manager version, refresh the Kubernetes Secret, then restart the controller.
- **Cleanup of finished workers:** finished one-shot worker Pods stay until deleted.

The exact commands are in [`helm/README.md`](helm/README.md), step 9.

## Validation

A healthy deployment has:

- The `gke-workers` controller Deployment running in `cursord`.
- At least one worker Pod (with `warmIdle=1`) connected.
- Pool `gke-workers` visible under **Any repo** in Cursor Cloud Agents.
- When you start an agent, the warm Pod turns busy (or a new Pod appears in claim mode) and the controller spawns a replacement.

```bash
kubectl -n cursord get deploy,pods -l app.kubernetes.io/instance=gke-workers
kubectl -n cursord logs -l app.kubernetes.io/component=controller -f
kubectl -n cursord get pods -l app.kubernetes.io/component=worker
kubectl -n cursord logs -l app.kubernetes.io/component=worker --tail 100
```

The AWS lab documents these lines in a healthy worker log. Exact text can vary by CLI version, and any-repo workers have no `Repo` line.

```text
Worker is now running
Registering to worker pool
Repo: <owner>/<repo>
Pool: <pool-name>
```

## Troubleshooting

### Invalid API Key Or HTTP 401

Pool workers only accept a Cursor **service account API key**. Refresh the Kubernetes Secret from a corrected Secret Manager version and restart the controller.

### Worker Connected, No Agent Lands On It

**Allow Self-Hosted Machines** must be on. The pool name must match exactly (case-sensitive). The Cursor GitHub App needs access to the repo.

### `exec format error`

The image architecture differs from the machine. Build `linux/amd64` for E2 and N2, `linux/arm64` for T2A and C4A.

### Timeouts Reaching Cursor Or GitHub

Check that Cloud NAT covers the subnet:

```bash
gcloud compute routers get-status ROUTER --region REGION
```

Behind a proxy, set `HTTPS_PROXY` for the worker.

### `ImagePullBackOff`

Check the image path and tag. The node service account needs Artifact Registry Reader.

### Controller CrashLoop, `kubectl` Not Found

Build from `docker/Dockerfile.gcp`, or set `controller.image` to an image with `agent` and `kubectl`.

### `unrecognized_keys` / `workerReadyTimeoutSeconds`

The CLI in the image is too old. Rebuild (`2026.09.03-a76a283` or later).

### Pool Missing From The Picker

Register it ([`helm/README.md`](helm/README.md), step 5) and look under **Any repo**. The Helm `pool` value must match.

### Worker Pods Pending

Raise `--max-nodes` or lower `resources.requests`.

### `get-credentials` Auth Plugin Error

Install `gke-gcloud-auth-plugin`.

### Controller Exits: Session Tokens Not Enabled

Ask Cursor to enable private-worker session tokens, or set `auth.sessionToken=false`.

## Cleanup

Uninstall the release and delete the cluster, network, and supporting resources when the demo is done. The implementation guide includes the exact teardown commands.
