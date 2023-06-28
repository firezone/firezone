output "service_account" {
  value = google_service_account.application
}

output "target_tags" {
  value = ["app-${local.application_name}"]
}

output "instances" {
  value = google_compute_region_instance_group_manager.application
}
