# Compute Engine + Docker Guide

Use this README for the architecture, operating model, validation, and troubleshooting. Use [`terraform/README.md`](terraform/README.md) for step-by-step setup commands.

## When To Use Compute Engine

This is the smallest footprint in the lab: one worker container on one private VM, serving one repository. It fits demos and proofs of concept.

Use [GKE](../gke/README.md) instead for concurrent sessions, warm workers, or many repositories.

## What Gets Created

Terraform creates:

- One VPC and subnet with Private Google Access and no external IPs.
- One Cloud Router and Cloud NAT with a static egress IP.
- One firewall rule allowing SSH only from IAP (`35.235.240.0/20`).
- One Artifact Registry repository for the worker image.
- One Secret Manager secret container for the Cursor service account key.
- One service account that can pull the image, read the secret, and write logs.
- One Shielded VM (Debian 12, Secure Boot, OS Login).

Terraform creates only the secret container. The key value is uploaded with gcloud so it does not land in Terraform state.

## Architecture

The VM runs one Docker container named `cursor-worker`. It uses the shared worker image from Artifact Registry and connects outbound to Cursor over HTTPS. The container's [entrypoint](../docker/entrypoint.sh) runs `agent worker --pool gce-lab ... start`.

The workspace lives on the VM at `/opt/cursor/worker` and is mounted into the container at `/workspace`. Its `origin` is `WORKER_REPOSITORY_URL`, so Cursor routes agents for that repository to this worker.

A repo-bound worker [uses the checkout it already has](https://cursor.com/docs/cloud-agent/self-hosted#environments-on-self-hosted-machines) and does not clone. To give agents real code, the startup script can clone the repository once with an optional read-only Git token. The token is passed as a one-off header and is not written to `.git/config`.

## Startup Script

[`startup.sh.tpl`](terraform/startup.sh.tpl) runs on every boot and:

1. Installs Docker and Git.
2. Waits up to 10 minutes for the API key in Secret Manager.
3. On first boot, clones the repository with the Git token, or runs `git init` without one. Then sets `origin`.
4. Writes `/etc/cursor/worker.env` (mode 0600).
5. Waits up to 10 minutes for the worker image and pulls it.
6. Replaces and starts the `cursor-worker` container.

## Network And Security Model

- No external IP and no inbound rules except SSH from IAP.
- Egress leaves through Cloud NAT on one static IP you can allowlist (`nat_egress_ip` output).
- Artifact Registry and Secret Manager are reached over Private Google Access.
- Admin access uses IAP TCP forwarding with OS Login.

## Operating Model

One worker runs on one VM, with no autoscaling.

Docker reads `--env-file` only when a container is created. After rotating the key or pushing an image with the same tag, rerun the startup script. Changing the image tag in Terraform replaces the VM.

## Validation

A healthy deployment has:

- One running `cursor-worker` container.
- `/readyz` responding on `127.0.0.1:8080` inside the container.
- Worker logs showing the expected pool and repo.
- The pool selectable under your repository in [cursor.com/agents](https://cursor.com/agents).

A healthy worker log includes:

```text
Worker is now running
Registering to worker pool
Repo: <owner>/<repo>
Pool: gce-lab
```

## Troubleshooting

### API Key Is Invalid

Pool workers require a Cursor [service account](https://cursor.com/docs/account/enterprise/service-accounts) API key. Other key types are rejected.

### Bootstrap Keeps Waiting

The log loops on `Waiting for Cursor API key` or `Waiting for worker image`. Upload the key or push the image, then rerun the startup script.

### Clone Fails On First Boot

The token in `cursor-git-read-token` needs read access to the repository. The bootstrap stops before starting the worker. Fix the token and rerun the startup script.

### Agent Sees An Empty Repository

Without a Git token the workspace is only `git init` plus `origin`. Add the token, or clone into `/opt/cursor/worker` yourself.

### Container Fails With `exec format error`

The image architecture differs from the VM. Build `linux/amd64` for E2 and N2, or `linux/arm64` for T2A and C4A.

### Worker Cannot Reach Cursor

Check Cloud NAT with `gcloud compute routers get-status cursor-worker-lab-router --region REGION`. Behind a proxy, set `HTTPS_PROXY` for the worker.

### IAP SSH Fails

Grant the IAP and OS Login roles from the implementation guide.

## Cleanup

Destroy the resources when the demo is done. The implementation guide has the command.
