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
      "docs.${local.tld}",
      "blog.${local.tld}",
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

  # docs.firezone.dev -> https://www.firezone.dev/docs{uri}
  host_rule {
    hosts        = ["docs.${local.tld}"]
    path_matcher = "firezone-docs-redirects"
  }

  path_matcher {
    name = "firezone-docs-redirects"

    default_url_redirect {
      host_redirect          = "www.firezone.dev"
      prefix_redirect        = "/docs"
      https_redirect         = true
      redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
      strip_query            = false
    }
  }

  # blog.firezone.dev -> https://www.firezone.dev/blog{uri}
  host_rule {
    hosts        = ["blog.${local.tld}"]
    path_matcher = "firezone-blog-redirects"
  }

  path_matcher {
    name = "firezone-blog-redirects"

    default_url_redirect {
      host_redirect          = "www.firezone.dev"
      prefix_redirect        = "/blog"
      https_redirect         = true
      redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
      strip_query            = false
    }
  }

  # rest of the hosts -> https://www.firezone.dev{uri}
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

  ssl_policy = google_compute_ssl_policy.tld.self_link
  ssl_certificates = [
    google_compute_managed_ssl_certificate.tld.self_link,
  ]

  quic_override = "NONE"
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
