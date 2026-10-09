# Compute Engine + Docker Guide

Use this README to understand the Compute Engine architecture, operating model, validation expectations, and troubleshooting paths. Use [`terraform/README.md`](terraform/README.md) for the step-by-step setup runbook.

## When To Use Compute Engine

The Compute Engine + Docker path is the smallest GCP footprint in this repo. It is a good fit for demos, proofs of concept, and customers that want one repo-bound self-hosted Cursor worker before adopting GKE.

Use [GKE](../gke/README.md) instead when the customer needs concurrent sessions, many repos, warm idle workers, or per-request worker Pods.

## Documentation Map

- This README: architecture, resource summary, security model, operations, validation, and troubleshooting.
- [`terraform/README.md`](terraform/README.md): variables, Terraform commands, key upload, image publishing, IAP access, worker validation, updates, key rotation, and cleanup.

## What Gets Created

Terraform ([`terraform/main.tf`](terraform/main.tf)) creates:

- A custom VPC and one subnet (`10.10.0.0/24`) with Private Google Access.
- A Cloud Router and Cloud NAT using one static external IP (output `nat_egress_ip`).
- One firewall rule allowing `tcp:22` only from the IAP range `35.235.240.0/20` to VMs tagged `cursor-worker`.
- One Artifact Registry Docker repository (`cursor-workers`) for the worker image.
- One Secret Manager secret container (`cursor-worker-api-key`) for the Cursor service account key.
- One service account (`cursor-worker-lab-sa`) with Artifact Registry Reader on the repository, Secret Accessor on the key secret (and on the Git token secret, if set), and Logs Writer on the project.
- One `e2-standard-2` Shielded VM (Debian 12, 30 GB boot disk, Secure Boot, OS Login, no external IP) named `cursor-worker-lab`.

Terraform creates only the secret container. The service account key value is added separately with `gcloud`, so it never lands in Terraform state.

## Architecture

The VM runs one Docker container named `cursor-worker`. The container uses the shared worker image from Artifact Registry, starts `agent worker --pool` through [`docker/entrypoint.sh`](../docker/entrypoint.sh), and connects outbound to Cursor over HTTPS. No inbound ports are required for Cursor Cloud Agents.

The worker is repo-bound. It serves the repository in `worker_repository_url` under pool `gce-lab`.

The workspace lives on the VM at `/opt/cursor/worker` and is mounted into the container at `/workspace`. Its git `origin` is set to `worker_repository_url` so Cursor can derive the repository label.

Google APIs (Artifact Registry, Secret Manager) are reached through Private Google Access. Everything else, including Cursor, GitHub, and package mirrors, leaves through Cloud NAT on the static IP.

## Bootstrap Flow

[`terraform/startup.sh.tpl`](terraform/startup.sh.tpl) is the VM startup script. It runs on every boot and is idempotent. Each run:

1. Installs `docker.io` and `git` if Docker is missing, then enables Docker.
2. Reads the Cursor service account key from Secret Manager, retrying every 10 seconds for about 10 minutes.
3. If `/opt/cursor/worker` is not yet a git repo: clones `worker_repository_url` with the read-only Git token when `git_token_secret_id` is set, otherwise runs `git init`.
4. Resets `origin` to `worker_repository_url`.
5. Writes `/etc/cursor/worker.env` (mode `0600`) with the key, pool name, idle timeout, and labels file path.
6. Removes any existing `cursor-worker` container, logs Docker into Artifact Registry with the VM's access token, and pulls the image, retrying for about 10 minutes.
7. Starts a new `cursor-worker` container with `--restart unless-stopped`, `--env-file /etc/cursor/worker.env`, and `/opt/cursor/worker` mounted as `/workspace`.

Output goes to `/var/log/cursor-worker-bootstrap.log` and the serial console.

The Git token is passed to `git clone` as a one-off header and is not written to `.git/config`.

## Network And Security Model

- The worker connects outbound to Cursor over HTTPS. Cursor never connects in.
- The VM has no external IP. The only ingress rule is SSH from IAP's range.
- Administrative shell access is IAP TCP forwarding with OS Login.
- Shielded VM with Secure Boot. Persistent Disk is encrypted by default.
- The metadata server requires the `Metadata-Flavor` header.
- The VM service account can pull from the worker repository, read only the configured secrets, and write logs.
- The Cursor key never enters Terraform state.

## Operating Model

This path runs one worker container on one VM. There is no autoscaling.

- **Key rotation, or a re-pushed image with the same tag:** add a secret version or push the image, then rerun the startup script. The script always recreates the container, because Docker reads `--env-file` only at container creation.
- **Changing `worker_image_tag` in Terraform replaces the VM,** because a change to `metadata_startup_script` forces recreation. The boot disk, including `/opt/cursor/worker`, is recreated.
- **The workspace persists** across sessions and reboots on the same VM. Reset it if agents should start clean.

## Validation

A healthy deployment has:

- One running VM with no external IP.
- IAP SSH access to the VM.
- One running `cursor-worker` Docker container.
- Worker logs showing registration to pool `gce-lab` and the expected repo.
- The pool visible and selectable in Cursor Cloud Agents for that repository.
- Cursor GitHub App access granted to the target repository.

Useful host checks:

```bash
sudo docker ps --filter name=cursor-worker
sudo docker logs -f cursor-worker
sudo systemctl status docker
sudo tail -f /var/log/cursor-worker-bootstrap.log
```

The AWS lab documents these lines in a healthy repo-bound worker log. Exact text can vary by CLI version.

```text
Worker is now running
Registering to worker pool
Repo: <owner>/<repo>
Pool: <pool-name>
```

## Troubleshooting

### Invalid API Key Or HTTP 401

Pool workers only accept a Cursor **service account API key**. Add the correct key as a new secret version and rerun the startup script.

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

### Log Loops On "Waiting for Cursor API key"

Add a secret version. The VM service account needs Secret Accessor on the secret.

### Log Loops On "Waiting for worker image"

Push the image with the tag in `worker_image_tag`. The VM service account needs Artifact Registry Reader. Then rerun the startup script.

### Clone Fails On First Boot

Check that the token in `cursor-git-read-token` has read access to the repo. The bootstrap stops before starting the worker. Fix the token and rerun the startup script.

### IAP SSH Fails

Allow `35.235.240.0/20` on `tcp:22` (the module does). Grant the roles in [`terraform/README.md`](terraform/README.md), step 7.

### Agent Runs But The Repo Looks Empty

Without a Git token the workspace is `git init` plus `origin` only. Set up the read-only token ([`terraform/README.md`](terraform/README.md), step 3), or clone the repo into `/opt/cursor/worker` yourself. See [Open Items To Confirm](../README.md#open-items-to-confirm).

## Cleanup

Destroy the resources when the demo is done to stop GCP spend. The implementation guide includes the exact cleanup commands.
