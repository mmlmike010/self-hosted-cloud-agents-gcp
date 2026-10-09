variable "project_id" { type = string }
# HTTPS clone URL, for example https://github.com/OWNER/REPO.git
variable "worker_repository_url" { type = string }
variable "region" {
  type    = string
  default = "us-east4"
}
variable "zone" {
  type    = string
  default = "us-east4-a"
}
variable "name" {
  type    = string
  default = "cursor-worker-lab"
}
variable "machine_type" {
  type    = string
  default = "e2-standard-2"
}
variable "worker_image_tag" {
  type    = string
  default = "latest"
}
variable "worker_pool_name" {
  type    = string
  default = "gce-lab"
}
variable "artifact_repository" {
  type    = string
  default = "cursor-workers"
}
variable "secret_id" {
  type    = string
  default = "cursor-worker-api-key"
}
# Optional: Secret Manager secret holding a read-only Git token. When set, the
# startup script clones worker_repository_url into the workspace on first boot.
variable "git_token_secret_id" {
  type    = string
  default = ""
}
