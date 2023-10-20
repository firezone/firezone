output "service_account" {
  value = google_service_account.application
}

output "target_tags" {
  value = local.application_tags
}

output "instance_template" {
  value = google_compute_instance_template.application
}

output "instance_group" {
  value = google_compute_region_instance_group_manager.application
}
