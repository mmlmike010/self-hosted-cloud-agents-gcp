# Path A: Compute Engine + Docker

One Shielded VM in a private VPC runs the worker image under Docker. It serves one repository (`WORKER_REPOSITORY_URL`) in the Team Pool `gce-lab`. Good for a proof of concept. For concurrent sessions and many repositories, use [Path B](../gke/).

## What Terraform creates

| Resource | Details |
| --- | --- |
| VPC + subnet | `10.10.0.0/24`, Private Google Access on, no external IPs |
| Cloud Router + Cloud NAT | One static egress IP (`nat_egress_ip` output) |
| Firewall rule | `tcp:22` from `35.235.240.0/20` only ([IAP TCP forwarding](https://docs.cloud.google.com/iap/docs/using-tcp-forwarding)) |
| Artifact Registry | Docker repository `cursor-workers` |
| Secret Manager | Secret container `cursor-worker-api-key`. The key value is added with gcloud, so it never lands in Terraform state. |
| Service account | `cursor-worker-lab-sa`: Artifact Registry Reader on the repository, Secret Accessor on the secret (and the Git token secret, if set), Logs Writer |
| VM | `e2-standard-2`, Debian 12, Secure Boot, OS Login, [startup script](terraform/startup.sh.tpl) that reruns on every boot |

The startup script installs Docker and Git, waits up to 10 minutes each for a secret version and for the image, writes `/etc/cursor/worker.env` (mode 0600), and runs the container with `/opt/cursor/worker` mounted at `/workspace`. The container's [entrypoint](../docker/entrypoint.sh) starts `agent worker --pool gce-lab ... start`.

## Steps

Run everything from the repository root with `.env` filled in (see the [top-level README](../README.md#quick-start)). Each `make` target is a thin wrapper, so read the [Makefile](../Makefile) to see the exact commands.

### 1. Credentials for Terraform

```bash
gcloud auth application-default login
make apis
```

### 2. Optional, recommended: a read-only Git token

A repo-bound pool worker [uses the checkouts it already has](https://cursor.com/docs/cloud-agent/self-hosted#environments-on-self-hosted-machines) and does not clone. To give the agent real code, store a read-only token (for GitHub, a fine-grained token with **Contents: read** on the repository). On first boot the VM clones the repository with it. The token is sent as a one-off HTTP header and is not written to `.git/config`.

```bash
make gce-git-token                       # prompts for the token
# then set GIT_TOKEN_SECRET_ID=cursor-git-read-token in .env
```

Skip this only if you will populate `/opt/cursor/worker` yourself.

### 3. Apply

The Makefile passes `.env` to Terraform as `TF_VAR_*` variables. If you prefer a tfvars file, copy [`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example) to `terraform.tfvars` and run `terraform -chdir=gce/terraform apply` directly (a tfvars file takes precedence over `TF_VAR_*`).

```bash
make gce-init
make gce-plan
make gce-apply
```

The VM can boot before the key and image exist. The startup script waits for both.

### 4. Upload the service account API key

```bash
make gce-put-key                         # prompts for the key unless CURSOR_API_KEY is exported
```

Create the key under a Cursor [service account](https://cursor.com/docs/account/enterprise/service-accounts#managing-api-keys). Pool workers reject other key types.

### 5. Build and push the image

Terraform created the registry in step 3, so push after applying. Use `PLATFORM=linux/amd64` for E2 and N2 machine types, `linux/arm64` for Arm types such as T2A and C4A (and set `boot_image` to an Arm image).

```bash
make image
```

### 6. Grant yourself SSH through IAP

OS Login with sudo needs IAP-secured Tunnel User, Compute OS Admin Login, and Service Account User on the VM's service account ([OS Login roles](https://docs.cloud.google.com/compute/docs/oslogin/set-up-oslogin)).

```bash
make gce-access ADMIN_MEMBER=user:you@example.com
```

### 7. Verify

```bash
make gce-logs                            # startup script output from the serial console, no SSH needed
make gce-ssh
```

On the VM:

```bash
sudo tail -n 100 /var/log/cursor-worker-bootstrap.log
sudo docker logs -f cursor-worker
sudo docker exec cursor-worker curl -fsS http://127.0.0.1:8080/readyz
```

A healthy repo-bound worker logs lines like the ones below (exact text varies by CLI version). Then follow [Verify an agent picks up a job](../README.md#verify-an-agent-picks-up-a-job): pick the repository that matches `WORKER_REPOSITORY_URL` and the pool `gce-lab`.

```text
Worker is now running
Registering to worker pool
Repo: <owner>/<repo>
Pool: gce-lab
```

### 8. If the bootstrap timed out

Add the missing secret version or push the missing image, then rerun the startup script in place. No VM replacement needed.

```bash
make gce-rerun
```

## Day 2

- **Rotate the key or re-push the same tag:** `make gce-put-key` or `make image`, then `make gce-rerun`. The script always replaces the container, because Docker reads `--env-file` only when a container is created. Then disable the old key version with `gcloud secrets versions disable VERSION --secret cursor-worker-api-key`.
- **Change `TAG`:** `make gce-apply` replaces the VM, because a change to `metadata_startup_script` forces a new instance. The boot disk, including `/opt/cursor/worker`, is replaced too.
- **Workspace state** persists across sessions and reboots on the same VM. Reset `/opt/cursor/worker` if agents should start clean.
- **Static egress IP** for allowlists: `terraform -chdir=gce/terraform output nat_egress_ip`.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| `Invalid API key` or HTTP 401 | Pool workers only accept a service account API key. |
| Worker connected, no agent lands on it | Allow Self-Hosted Machines must be on. The pool name must match exactly. See [Open items](../README.md#open-items-to-confirm) on repository access. |
| Log loops on `Waiting for Cursor API key` | Add a secret version (`make gce-put-key`). The VM service account needs Secret Accessor on the secret. |
| Log loops on `Waiting for worker image` | Push the image with the tag in `TAG` (`make image`), then `make gce-rerun`. The VM service account needs Artifact Registry Reader. |
| Clone fails on first boot | Check the token in `cursor-git-read-token` can read the repository. The bootstrap stops before starting the worker. Fix the token, then `make gce-rerun`. |
| Agent runs but the repository looks empty | The workspace is `git init` plus `origin` only. Do step 2, or clone into `/opt/cursor/worker` yourself. |
| `exec format error` | Image architecture differs from the VM. Match `PLATFORM` to the machine type. |
| Timeouts reaching Cursor or GitHub | Check Cloud NAT: `gcloud compute routers get-status cursor-worker-lab-router --region REGION`. Behind a proxy, set `HTTPS_PROXY` for the worker. |
| IAP SSH fails | The firewall rule must allow `35.235.240.0/20` on `tcp:22` (the module does). Redo step 6. |

## Teardown

```bash
make gce-destroy
gcloud secrets delete cursor-git-read-token     # only if you created it in step 2
```
