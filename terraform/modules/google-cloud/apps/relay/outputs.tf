output "service_account" {
  value = google_service_account.application
}

output "target_tags" {
  value = ["app-${local.application_name}"]
}

output "instances" {
  value = var.instances
}

output "network" {
  value = google_compute_network.network.self_link
}
