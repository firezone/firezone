resource "google_project_service" "compute" {
  project = module.google-cloud-project.project.project_id
  service = "servicenetworking.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "servicenetworking" {
  project = module.google-cloud-project.project.project_id
  service = "servicenetworking.googleapis.com"

  disable_on_destroy = false
}

# Create a global address that will be used for the load balancer
resource "google_compute_global_address" "tld-ipv4" {
  project = module.google-cloud-project.project.project_id

  name = replace(local.tld, ".", "-")
}

# Create a SSL policy
resource "google_compute_ssl_policy" "tld" {
  project = module.google-cloud-project.project.project_id

  name = replace(local.tld, ".", "-")

  min_tls_version = "TLS_1_2"
  profile         = "RESTRICTED"

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

# Create a managed SSL certificate
resource "google_compute_managed_ssl_certificate" "tld" {
  project = module.google-cloud-project.project.project_id

  name = replace(local.tld, ".", "-")

  type = "MANAGED"

  managed {
    domains = [
      local.tld,
    ]
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

# URL maps are used to define redirect rules for incoming requests
resource "google_compute_url_map" "redirects" {
  project = module.google-cloud-project.project.project_id

  name = "${replace(local.tld, ".", "-")}-www-redirect"

  default_url_redirect {
    host_redirect          = "www.${local.tld}"
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

# HTTP(s) proxies are used to route requests to the appropriate URL maps
resource "google_compute_target_http_proxy" "tld" {
  project = module.google-cloud-project.project.project_id
  name    = "${replace(local.tld, ".", "-")}-http"

  url_map = google_compute_url_map.redirects.self_link
}

resource "google_compute_target_https_proxy" "tld" {
  project = module.google-cloud-project.project.project_id
  name    = "${replace(local.tld, ".", "-")}-https"

  url_map = google_compute_url_map.redirects.self_link

  ssl_certificates = [google_compute_managed_ssl_certificate.tld.self_link]
  ssl_policy       = google_compute_ssl_policy.tld.self_link
  quic_override    = "NONE"
}

# Forwarding rules are used to route incoming requests to the appropriate proxies
resource "google_compute_global_forwarding_rule" "http" {
  project = module.google-cloud-project.project.project_id

  name = replace(local.tld, ".", "-")
  labels = {
    managed_by = "terraform"
  }

  target     = google_compute_target_http_proxy.tld.self_link
  ip_address = google_compute_global_address.tld-ipv4.address
  port_range = "80"

  load_balancing_scheme = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "https" {
  project = module.google-cloud-project.project.project_id

  name = "${replace(local.tld, ".", "-")}-https"
  labels = {
    managed_by = "terraform"
  }

  target     = google_compute_target_https_proxy.tld.self_link
  ip_address = google_compute_global_address.tld-ipv4.address
  port_range = "443"

  load_balancing_scheme = "EXTERNAL"
}

# Backend service is required but not used
resource "google_compute_backend_service" "tld" {
  project = module.google-cloud-project.project.project_id

  name = replace(local.tld, ".", "-")

  load_balancing_scheme = "EXTERNAL"

  protocol = "HTTP"

  timeout_sec = 10

  custom_request_headers = [
    "X-Geo-Location-Region:{client_region}",
    "X-Geo-Location-City:{client_city}",
    "X-Geo-Location-Coordinates:{client_city_lat_long}",
  ]

  custom_response_headers = [
    "X-Cache-Hit: {cdn_cache_status}",
    "Content-Security-Policy: default-src 'self'",
    "X-Frame-Options: DENY",
    "Strict-Transport-Security: max-age=63072000; includeSubDomains; preload",
  ]

  log_config {
    enable      = false
    sample_rate = "1.0"
  }
}
