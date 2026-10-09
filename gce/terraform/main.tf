terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  registry_host = "${var.region}-docker.pkg.dev"
  image_repo    = "${local.registry_host}/${var.project_id}/${var.artifact_repository}"
  worker_image  = "${local.image_repo}/cursor-self-hosted-worker:${var.worker_image_tag}"
  sa_member     = "serviceAccount:${google_service_account.worker.email}"
}

# Private subnet, IAP-only SSH, egress through Cloud NAT on a static IP
resource "google_compute_network" "vpc" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name                     = "${var.name}-subnet"
  network                  = google_compute_network.vpc.id
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = true
}

resource "google_compute_router" "router" {
  name    = "${var.name}-router"
  network = google_compute_network.vpc.id
}

resource "google_compute_address" "nat" {
  name = "${var.name}-nat-ip"
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.name}-nat"
  router                             = google_compute_router.router.name
  nat_ip_allocate_option             = "MANUAL_ONLY"
  nat_ips                            = [google_compute_address.nat.self_link]
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_firewall" "iap_ssh" {
  name          = "${var.name}-allow-iap-ssh"
  network       = google_compute_network.vpc.name
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["cursor-worker"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Registry and secret container. The key value is added with gcloud, never via Terraform.
resource "google_artifact_registry_repository" "worker" {
  location      = var.region
  repository_id = var.artifact_repository
  format        = "DOCKER"
}

resource "google_secret_manager_secret" "key" {
  secret_id = var.secret_id
  replication {
    auto {}
  }
}

# Least-privilege identity for the VM
resource "google_service_account" "worker" {
  account_id = "${var.name}-sa"
}

resource "google_artifact_registry_repository_iam_member" "pull" {
  location   = var.region
  repository = google_artifact_registry_repository.worker.name
  role       = "roles/artifactregistry.reader"
  member     = local.sa_member
}

resource "google_secret_manager_secret_iam_member" "read" {
  secret_id = google_secret_manager_secret.key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.sa_member
}

resource "google_secret_manager_secret_iam_member" "git_token" {
  count     = var.git_token_secret_id == "" ? 0 : 1
  secret_id = var.git_token_secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.sa_member
}

resource "google_project_iam_member" "logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = local.sa_member
}

resource "google_compute_instance" "worker" {
  name         = var.name
  zone         = var.zone
  machine_type = var.machine_type
  tags         = ["cursor-worker"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 30
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id # no access_config: no external IP
  }

  service_account {
    email  = google_service_account.worker.email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot = true
  }

  metadata = { enable-oslogin = "TRUE" }

  metadata_startup_script = templatefile("${path.module}/startup.sh.tpl", {
    project_id          = var.project_id
    registry_host       = local.registry_host
    worker_image        = local.worker_image
    secret_id           = var.secret_id
    worker_pool_name    = var.worker_pool_name
    repository_url      = var.worker_repository_url
    git_token_secret_id = var.git_token_secret_id
  })

  depends_on = [
    google_artifact_registry_repository_iam_member.pull,
    google_secret_manager_secret_iam_member.read,
    google_secret_manager_secret_iam_member.git_token,
    google_compute_router_nat.nat,
  ]
}
