output "nat_egress_ip" { value = google_compute_address.nat.address }
output "worker_service_account" { value = google_service_account.worker.email }
