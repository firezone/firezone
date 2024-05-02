output "service_account" {
  value = google_service_account.application
}

output "target_tags" {
  value = local.vm_network_tags
}

output "instance" {
  value = google_compute_instance.vm
}

output "internal_ipv4_address" {
  value = google_compute_address.ipv4.address
}
