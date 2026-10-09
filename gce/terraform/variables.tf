variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "worker_repository_url" {
  description = "HTTPS clone URL the worker serves, for example https://github.com/OWNER/REPO.git."
  type        = string
}

variable "region" {
  type    = string
  default = "us-east4"
}

variable "zone" {
  type    = string
  default = "us-east4-a"
}

variable "name" {
  description = "Prefix for every resource, and the VM name."
  type        = string
  default     = "cursor-worker-lab"
}

variable "machine_type" {
  description = "Size it like a CI runner for the repository. Arm types need an arm64 image and boot image."
  type        = string
  default     = "e2-standard-2"
}

variable "boot_image" {
  type    = string
  default = "debian-cloud/debian-12"
}

variable "artifact_repository" {
  description = "Artifact Registry Docker repository created by this module."
  type        = string
  default     = "cursor-workers"
}

variable "worker_image_name" {
  type    = string
  default = "cursor-self-hosted-worker"
}

variable "worker_image_tag" {
  description = "Changing this replaces the VM, because it changes the startup script."
  type        = string
  default     = "latest"
}

variable "worker_pool_name" {
  type    = string
  default = "gce-lab"
}

variable "worker_idle_release_timeout" {
  description = "Seconds the worker stays connected after a session ends. Docker restarts it after it exits."
  type        = number
  default     = 600
}

variable "secret_id" {
  description = "Secret Manager secret that holds the Cursor service account API key. Terraform creates the container only."
  type        = string
  default     = "cursor-worker-api-key"
}

variable "git_token_secret_id" {
  description = "Optional existing Secret Manager secret with a read-only Git token. When set, the VM clones worker_repository_url on first boot."
  type        = string
  default     = ""
}
