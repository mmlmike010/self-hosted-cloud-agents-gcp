# Offline test with a mocked provider: terraform test (Terraform 1.7 or later)
mock_provider "google" {}

variables {
  project_id            = "PROJECT_ID"
  worker_repository_url = "https://github.com/OWNER/REPO.git"
  worker_image_tag      = "v1"
}

run "without_git_token" {
  command = apply

  assert {
    condition     = length(google_secret_manager_secret_iam_member.git_token) == 0
    error_message = "No Git token binding expected when git_token_secret_id is empty."
  }

  assert {
    condition     = length(google_compute_instance.worker.network_interface[0].access_config) == 0
    error_message = "The worker VM must not have an external IP."
  }

  assert {
    condition     = output.worker_image == "us-east4-docker.pkg.dev/PROJECT_ID/cursor-workers/cursor-self-hosted-worker:v1"
    error_message = "Unexpected worker image reference."
  }

  assert {
    condition     = strcontains(google_compute_instance.worker.metadata_startup_script, "CURSOR_WORKER_POOL_NAME=gce-lab")
    error_message = "Startup script must set the pool name."
  }
}

run "with_git_token" {
  command = apply

  variables {
    git_token_secret_id = "cursor-git-read-token"
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.git_token) == 1
    error_message = "Git token binding expected when git_token_secret_id is set."
  }

  assert {
    condition     = strcontains(google_compute_instance.worker.metadata_startup_script, "GIT_TOKEN_SECRET_ID=\"cursor-git-read-token\"")
    error_message = "Startup script must reference the Git token secret."
  }
}
