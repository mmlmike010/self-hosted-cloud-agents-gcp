output "instance_name" {
  value = google_compute_instance.worker.name
}

output "zone" {
  value = var.zone
}

output "nat_egress_ip" {
  description = "Static egress IP to allowlist on your Git host, proxies, and internal services."
  value       = google_compute_address.nat.address
}

output "worker_service_account" {
  value = google_service_account.worker.email
}

output "worker_image" {
  description = "Push the worker image to exactly this reference."
  value       = local.worker_image
}

output "ssh_command" {
  value = "gcloud compute ssh ${google_compute_instance.worker.name} --zone ${var.zone} --tunnel-through-iap"
}
