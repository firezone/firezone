# Create DNS records for the application
resource "google_dns_record_set" "application-ipv4" {
  count = var.application_dns_tld != null ? 1 : 0

  project = var.project_id

  name = "${var.application_dns_tld}."
  type = "A"
  ttl  = 300

  managed_zone = var.dns_managed_zone_name

  rrdatas = google_compute_global_address.ipv4[*].address

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

resource "google_dns_record_set" "application-ipv6" {
  count = var.application_dns_tld != null ? 1 : 0

  project = var.project_id

  name = "${var.application_dns_tld}."
  type = "AAAA"
  ttl  = 300

  managed_zone = var.dns_managed_zone_name

  rrdatas = google_compute_global_address.ipv6[*].address

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}
