locals {
  google_load_balancer_ip_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]

  google_health_check_ip_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16"
  ]

  public_application = var.application_dns_tld != null
}

# Define a security policy which allows to filter traffic by IP address,
# an edge security policy can also detect and block common types of web attacks
resource "google_compute_security_policy" "default" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name = local.application_name

  type = "CLOUD_ARMOR"

  advanced_options_config {
    json_parsing = "STANDARD"
    log_level    = "NORMAL"
  }

  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable          = local.public_application
      rule_visibility = "STANDARD"
    }
  }

  rule {
    description = "rate limit all requests that match the default rule"

    # TODO: disable preview when we make sure that rate limited logs look good for some time
    preview = true

    action   = "throttle"
    priority = "1"

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"

      enforce_on_key = "IP"

      rate_limit_threshold {
        count        = 240
        interval_sec = 60
      }
    }
  }

  rule {
    description = "block sanctioned countries"

    action   = "deny(403)"
    priority = "101"

    match {
      expr {
        expression = "request.path.matches('/sign_up') && !origin.region_code.matches('^RU|BY|KP|IR|SY|CU|VE|XC|XD$')"
      }
    }
  }

  rule {
    description = "log all requests that match preconfigured sqli-v33-stable OWASP rule"
    preview     = true

    action   = "deny(403)"
    priority = "1001"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    description = "log all requests that match preconfigured xss-v33-stable OWASP rule"
    preview     = true

    action   = "deny(403)"
    priority = "1002"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('xss-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    description = "log all requests that match preconfigured methodenforcement-v33-stable OWASP rule"
    preview     = true

    action   = "deny(403)"
    priority = "1003"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('methodenforcement-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    description = "log all requests that match preconfigured scannerdetection-v33-stable OWASP rule"
    preview     = true

    action   = "deny(403)"
    priority = "1004"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('scannerdetection-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    description = "log all requests that match preconfigured protocolattack-v33-stable OWASP rule"
    preview     = true

    action   = "deny(403)"
    priority = "1005"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('protocolattack-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    description = "log all requests that match preconfigured sessionfixation-v33-stable OWASP rule"
    preview     = true

    action   = "deny(403)"
    priority = "1006"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sessionfixation-v33-stable', {'sensitivity': 1})"
      }
    }
  }

  rule {
    description = "log all requests that match preconfigured cve-canary GCP rule"
    preview     = true

    action   = "deny(403)"
    priority = "1007"

    match {
      expr {
        expression = "evaluatePreconfiguredWaf('cve-canary', {'sensitivity': 2})"
      }
    }
  }

  rule {
    description = "default allow rule"

    action   = "allow"
    priority = "2147483647"

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.pubsub,
    google_project_service.bigquery,
    google_project_service.container,
    google_project_service.stackdriver,
    google_project_service.logging,
    google_project_service.monitoring,
    google_project_service.cloudprofiler,
    google_project_service.cloudtrace,
    google_project_service.servicenetworking,
  ]
}

# Expose the application ports via HTTP(S) load balancer with a managed SSL certificate and a static IP address
resource "google_compute_backend_service" "default" {
  for_each = local.public_application ? local.application_ports_by_name : {}

  project = var.project_id

  name = "${local.application_name}-backend-${each.value.name}"

  load_balancing_scheme = "EXTERNAL"

  port_name = each.value.name
  protocol  = "HTTP"

  timeout_sec                     = 86400
  connection_draining_timeout_sec = 120

  enable_cdn = var.application_cdn_enabled

  cdn_policy {
    cache_mode = "CACHE_ALL_STATIC"

    cache_key_policy {
      include_host         = true
      include_protocol     = true
      include_query_string = true
    }

    default_ttl = 3600
    client_ttl  = 3600
    max_ttl     = 86400
  }

  compression_mode = "DISABLED"

  custom_request_headers = [
    "X-Geo-Location-Region:{client_region}",
    "X-Geo-Location-City:{client_city}",
    "X-Geo-Location-Coordinates:{client_city_lat_long}",
  ]

  custom_response_headers = [
    "X-Cache-Hit: {cdn_cache_status}"
  ]

  session_affinity = "CLIENT_IP"

  health_checks = try([google_compute_health_check.port[each.key].self_link], null)

  security_policy = google_compute_security_policy.default[0].self_link

  backend {
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1
    group           = google_compute_region_instance_group_manager.application.instance_group

    # Do not send traffic to nodes that have CPU load higher than 80%
    # max_utilization = 0.8
  }

  log_config {
    enable      = false
    sample_rate = "1.0"
  }

  depends_on = [
    google_compute_region_instance_group_manager.application,
    google_compute_health_check.port,
  ]
}

## Create a SSL policy
resource "google_compute_ssl_policy" "application" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name = local.application_name

  min_tls_version = "TLS_1_2"
  profile         = "RESTRICTED"

  depends_on = [
    google_project_service.compute,
    google_project_service.pubsub,
    google_project_service.bigquery,
    google_project_service.container,
    google_project_service.stackdriver,
    google_project_service.logging,
    google_project_service.monitoring,
    google_project_service.cloudprofiler,
    google_project_service.cloudtrace,
    google_project_service.servicenetworking,
  ]
}

## Create a managed SSL certificate
resource "google_compute_managed_ssl_certificate" "default" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name = "${local.application_name}-mig-lb-cert"

  type = "MANAGED"

  managed {
    domains = [
      var.application_dns_tld,
    ]
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

## Create URL map for the application
resource "google_compute_url_map" "default" {
  count = local.public_application && contains(keys(local.application_ports_by_name), "http") ? 1 : 0

  project = var.project_id

  name            = local.application_name
  default_service = google_compute_backend_service.default["http"].self_link

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

# Set up HTTP(s) proxies and redirect HTTP to HTTPS
resource "google_compute_url_map" "https_redirect" {
  count = local.public_application && contains(keys(local.application_ports_by_name), "http") ? 1 : 0

  project = var.project_id

  name = "${local.application_name}-https-redirect"

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

resource "google_compute_target_http_proxy" "default" {
  count = length(google_compute_url_map.https_redirect) > 0 ? 1 : 0

  project = var.project_id

  name = "${local.application_name}-http"

  url_map = google_compute_url_map.https_redirect[0].self_link
}

resource "google_compute_target_https_proxy" "default" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name = "${local.application_name}-https"

  url_map = google_compute_url_map.default[0].self_link

  ssl_certificates = google_compute_managed_ssl_certificate.default[*].self_link
  ssl_policy       = google_compute_ssl_policy.application[0].self_link
  quic_override    = "NONE"
}

# Allocate global addresses for the load balancer and set up forwarding rules
## IPv4
resource "google_compute_global_address" "ipv4" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name = "${local.application_name}-ipv4"

  ip_version = "IPV4"

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

resource "google_compute_global_forwarding_rule" "http" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name   = local.application_name
  labels = local.application_labels

  target     = google_compute_target_http_proxy.default[0].self_link
  ip_address = google_compute_global_address.ipv4[0].address
  port_range = "80"

  load_balancing_scheme = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "https" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name   = "${local.application_name}-https"
  labels = local.application_labels

  target     = google_compute_target_https_proxy.default[0].self_link
  ip_address = google_compute_global_address.ipv4[0].address
  port_range = "443"

  load_balancing_scheme = "EXTERNAL"
}

## IPv6
resource "google_compute_global_address" "ipv6" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name = "${local.application_name}-ipv6"

  ip_version = "IPV6"

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

resource "google_compute_global_forwarding_rule" "http_ipv6" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name   = "${local.application_name}-ipv6-http"
  labels = local.application_labels

  target     = google_compute_target_http_proxy.default[0].self_link
  ip_address = google_compute_global_address.ipv6[0].address
  port_range = "80"

  load_balancing_scheme = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "https_ipv6" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name   = "${local.application_name}-ipv6-https"
  labels = local.application_labels

  target     = google_compute_target_https_proxy.default[0].self_link
  ip_address = google_compute_global_address.ipv6[0].address
  port_range = "443"

  load_balancing_scheme = "EXTERNAL"
}

## Open HTTP ports for the load balancer
resource "google_compute_firewall" "http" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name    = "${local.application_name}-firewall-lb-to-instances-ipv4"
  network = var.vpc_network

  source_ranges = local.google_load_balancer_ip_ranges
  target_tags   = ["app-${local.application_name}"]

  dynamic "allow" {
    for_each = var.application_ports

    content {
      protocol = allow.value.protocol
      ports    = [allow.value.port]
    }
  }

  # We also enable UDP to allow QUIC if it's enabled
  dynamic "allow" {
    for_each = var.application_ports

    content {
      protocol = "udp"
      ports    = [allow.value.port]
    }
  }
}

## Open HTTP ports for the health checks
resource "google_compute_firewall" "http-health-checks" {
  project = var.project_id

  name    = "${local.application_name}-healthcheck"
  network = var.vpc_network

  source_ranges = local.google_health_check_ip_ranges
  target_tags   = ["app-${local.application_name}"]

  dynamic "allow" {
    for_each = var.application_ports

    content {
      protocol = allow.value.protocol
      ports    = [allow.value.port]
    }
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

# Allow outbound traffic
resource "google_compute_firewall" "egress-ipv4" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name      = "${local.application_name}-egress-ipv4"
  network   = var.vpc_network
  direction = "EGRESS"

  target_tags        = ["app-${local.application_name}"]
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "all"
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

resource "google_compute_firewall" "egress-ipv6" {
  count = local.public_application ? 1 : 0

  project = var.project_id

  name      = "${local.application_name}-egress-ipv6"
  network   = var.vpc_network
  direction = "EGRESS"

  target_tags        = ["app-${local.application_name}"]
  destination_ranges = ["::/0"]

  allow {
    protocol = "all"
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}
