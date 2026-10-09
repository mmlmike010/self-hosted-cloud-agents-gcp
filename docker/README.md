# Worker image

One image serves both paths. [`Dockerfile`](Dockerfile) builds on Ubuntu 24.04 with:

- the Cursor `agent` CLI from [cursor.com/install](https://cursor.com/docs/cloud-agent/self-hosted/pool#install-the-cli)
- `git` (needed when the worker serves git remotes or uses `--clone-git-repos`), plus `curl`, `jq`, `openssh-client`
- `kubectl`, checksum-verified, because the GKE controller's spawn hook creates worker Pods with it
- [`config/labels.json`](../config/labels.json) at `/etc/cursor/labels.json`
- [`entrypoint.sh`](entrypoint.sh) as the entrypoint (Path A and `make docker-run`; the GKE chart runs `agent` directly)

```bash
make docker-build                        # local build, tagged cursor-self-hosted-worker:local
make image                               # build for PLATFORM and push to Artifact Registry
```

## Entrypoint environment

| Variable | Default | Becomes |
| --- | --- | --- |
| `CURSOR_API_KEY` | required | Service account API key, read by `agent` |
| `CURSOR_WORKER_POOL_NAME` | `lab` | `--pool NAME` |
| `CURSOR_WORKER_DIR` | `/workspace` | `--worker-dir` |
| `CURSOR_WORKER_IDLE_RELEASE_TIMEOUT` | `600` | `--idle-release-timeout` (seconds) |
| `CURSOR_WORKER_LABELS_FILE` | `/etc/cursor/labels.json` | `--labels-file`, if the file exists |
| `CURSOR_WORKER_LABELS_JSON` | unset | Inline JSON labels, overrides the file |
| `CURSOR_WORKER_MANAGEMENT_ADDR` | unset | `--management-addr` for `/healthz`, `/readyz`, `/metrics` |
| `WORKER_REPOSITORY_URL` | unset | If `/workspace` has no `.git`, runs `git init` and adds this as `origin`, so the worker serves that repository |

Flags are documented in the [Team Pools CLI reference](https://cursor.com/docs/cloud-agent/self-hosted/pool#cli-reference).

## Pins

- `KUBECTL_VERSION` (`v1.36.5`): keep within one minor version of your GKE control plane ([version skew policy](https://kubernetes.io/releases/version-skew-policy/)).
- The install script installs whichever CLI build it currently points to (2026.10.01-e373342 when checked). For repeatable builds, keep a reviewed copy of the script in your repository and run that copy.
