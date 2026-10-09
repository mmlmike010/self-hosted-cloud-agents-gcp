# Self-Hosted Cloud Agents on Google Cloud

This lab shows how to run Cursor Cloud Agents on your own Google Cloud infrastructure with self-hosted [Team Pool](https://cursor.com/docs/cloud-agent/self-hosted/pool) workers. Cursor still handles orchestration, model inference, and the Cloud Agents experience, while workers run inside your GCP project to clone repos, run commands, edit files, execute builds and tests, and reach internal services.

Workers connect outbound to Cursor over HTTPS. No inbound access to the worker is required.

## Infrastructure Guides

| Infrastructure | General README | Implementation README |
| --- | --- | --- |
| Compute Engine + Docker | [`gce/README.md`](gce/README.md) | [`gce/terraform/README.md`](gce/terraform/README.md) |
| GKE + Helm | [`gke/README.md`](gke/README.md) | [`gke/helm/README.md`](gke/helm/README.md) |

Use the general READMEs for architecture, trade-offs, validation, and troubleshooting. Use the implementation READMEs for copy-paste setup commands. [`docs/reference.md`](docs/reference.md) has the diagram, required egress hosts, and open items.

- Compute Engine + Docker is the smallest footprint and runs one worker container on one private VM.
- GKE + Helm is the Kubernetes path, using Cursor's `k8s-workers` chart to start one worker Pod per agent request.

Validated offline only. Nothing has been deployed to a live GCP project yet.
