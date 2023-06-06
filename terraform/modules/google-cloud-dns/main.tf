resource "google_project_service" "dns" {
  project = var.project_id
  service = "dns.googleapis.com"

  disable_on_destroy = false
}

resource "google_dns_managed_zone" "main" {
  project = var.project_id

  name     = join("-", compact(split(".", var.tld)))
  dns_name = "${var.tld}."

  labels = {
    managed    = true
    managed_by = "terraform"
  }

  dnssec_config {
    kind          = "dns#managedZoneDnsSecConfig"
    non_existence = "nsec3"

    state = var.dnssec_enabled ? "on" : "off"

    default_key_specs {
      algorithm  = "rsasha256"
      key_length = 2048
      key_type   = "keySigning"
      kind       = "dns#dnsKeySpec"
    }

    default_key_specs {
      algorithm  = "rsasha256"
      key_length = 1024
      key_type   = "zoneSigning"
      kind       = "dns#dnsKeySpec"
    }
  }

  lifecycle {
    # prevent_destroy = true
    ignore_changes = []
  }

  depends_on = [
    google_project_service.dns
  ]
}
