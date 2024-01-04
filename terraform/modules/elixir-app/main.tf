locals {
  application_name    = var.application_name != null ? var.application_name : var.image
  application_version = var.application_version != null ? var.application_version : var.image_tag

  application_labels = merge({
    managed_by = "terraform"

    # Note: this labels are used to fetch a release name for Erlang Cluster
    application = local.application_name
  }, var.application_labels)

  application_environment_variables = concat([
    {
      name  = "RELEASE_HOST_DISCOVERY_METHOD"
      value = "gce_metadata"
    },
    {
      name = "PHOENIX_EXTERNAL_TRUSTED_PROXIES"
      value = jsonencode([
        "35.191.0.0/16",
        "130.211.0.0/22",
        google_compute_global_address.ipv4.address,
        google_compute_global_address.ipv6.address
      ])
    },
    {
      name  = "LOG_LEVEL"
      value = var.observability_log_level
    },
    {
      name  = "OTLP_ENDPOINT",
      value = "http://localhost:4318"
    },
    {
      name  = "OTEL_RESOURCE_ATTRIBUTES"
      value = "application.name=${local.application_name}"
    },
    {
      name  = "PLATFORM_ADAPTER"
      value = "Elixir.Domain.GoogleCloudPlatform"
    },
    {
      name = "PLATFORM_ADAPTER_CONFIG"
      value = jsonencode({
        project_id            = var.project_id
        service_account_email = google_service_account.application.email
      })
    }
  ], var.application_environment_variables)

  application_ports_by_name = { for port in var.application_ports : port.name => port }

  google_load_balancer_ip_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]

  google_health_check_ip_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16"
  ]
}

# Fetch most recent COS image
data "google_compute_image" "coreos" {
  family  = "cos-109-lts"
  project = "cos-cloud"
}

# Create IAM role for the application instances
resource "google_service_account" "application" {
  project = var.project_id

  account_id   = "app-${local.application_name}"
  display_name = "${local.application_name} app"
  description  = "Service account for ${local.application_name} application instances."
}

## Allow application service account to pull images from the container registry
resource "google_project_iam_member" "artifacts" {
  project = var.project_id

  role = "roles/artifactregistry.reader"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow fluentbit to injest logs
resource "google_project_iam_member" "logs" {
  project = var.project_id

  role = "roles/logging.logWriter"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow reporting application errors
resource "google_project_iam_member" "errors" {
  project = var.project_id

  role = "roles/errorreporting.writer"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow reporting metrics
resource "google_project_iam_member" "metrics" {
  project = var.project_id

  role = "roles/monitoring.metricWriter"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow reporting metrics
resource "google_project_iam_member" "service_management" {
  project = var.project_id

  role = "roles/servicemanagement.reporter"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow appending traces
resource "google_project_iam_member" "cloudtrace" {
  project = var.project_id

  role = "roles/cloudtrace.agent"

  member = "serviceAccount:${google_service_account.application.email}"
}

# Deploy app
resource "google_compute_instance_template" "application" {
  project = var.project_id

  name_prefix = "${local.application_name}-"

  description = "This template is used to create ${local.application_name} instances."

  machine_type = var.compute_instance_type
  region       = var.compute_instance_region

  can_ip_forward = false

  tags = ["app-${local.application_name}"]

  labels = merge({
    container-vm = data.google_compute_image.coreos.name

    # This variable can be used by Erlang Cluster not to join nodes of older versions
    version = local.application_version
  }, local.application_labels)


  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  disk {
    source_image = data.google_compute_image.coreos.self_link
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = var.vpc_subnetwork
    stack_type = "IPV4_IPV6"

    ipv6_access_config {
      network_tier = "PREMIUM"
    }
  }

  service_account {
    email = google_service_account.application.email

    scopes = concat([
      # Those are default scopes
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
      # Required to discover the other instances in the Erlang Cluster
      "https://www.googleapis.com/auth/compute.readonly"
    ], var.application_token_scopes)
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }

  metadata = {
    gce-container-declaration = yamlencode({
      spec = {
        containers = [{
          name  = local.application_name != null ? local.application_name : var.image
          image = "${var.container_registry}/${var.image_repo}/${var.image}:${var.image_tag}"
          env   = local.application_environment_variables
        }]

        volumes = []

        restartPolicy = "Always"
      }
    })

    user-data = templatefile("${path.module}/templates/cloud-init.yaml", {})

    google-logging-enabled       = "true"
    google-logging-use-fluentbit = "true"

    # Report health-related metrics to Cloud Monitoring
    google-monitoring-enabled = "true"
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
    google_project_iam_member.artifacts,
    google_project_iam_member.logs,
    google_project_iam_member.errors,
    google_project_iam_member.metrics,
    google_project_iam_member.service_management,
    google_project_iam_member.cloudtrace,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# Create health checks for the application ports
resource "google_compute_health_check" "port" {
  for_each = { for port in var.application_ports : port.name => port if try(port.health_check, null) != null }

  project = var.project_id

  name = "${local.application_name}-${each.key}"

  check_interval_sec  = each.value.health_check.check_interval_sec != null ? each.value.health_check.check_interval_sec : 5
  timeout_sec         = each.value.health_check.timeout_sec != null ? each.value.health_check.timeout_sec : 5
  healthy_threshold   = each.value.health_check.healthy_threshold != null ? each.value.health_check.healthy_threshold : 2
  unhealthy_threshold = each.value.health_check.unhealthy_threshold != null ? each.value.health_check.unhealthy_threshold : 2

  log_config {
    enable = false
  }

  dynamic "tcp_health_check" {
    for_each = try(each.value.health_check.tcp_health_check, null)[*]

    content {
      port = each.value.port

      response = lookup(tcp_health_check.value, "response", null)
    }
  }

  dynamic "http_health_check" {
    for_each = try(each.value.health_check.http_health_check, null)[*]

    content {
      port = each.value.port

      host         = lookup(http_health_check.value, "host", null)
      request_path = lookup(http_health_check.value, "request_path", null)
      response     = lookup(http_health_check.value, "response", null)
    }
  }

  dynamic "https_health_check" {
    for_each = try(each.value.health_check.https_health_check, null)[*]

    content {
      port = each.value.port

      host         = lookup(https_health_check.value, "host", null)
      request_path = lookup(https_health_check.value, "request_path", null)
      response     = lookup(http_health_check.value, "response", null)
    }
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

# Use template to deploy zonal instance group
resource "google_compute_region_instance_group_manager" "application" {
  project = var.project_id

  name = "${local.application_name}-group"

  base_instance_name        = local.application_name
  region                    = var.compute_instance_region
  distribution_policy_zones = var.compute_instance_availability_zones

  target_size = var.scaling_horizontal_replicas

  wait_for_instances        = true
  wait_for_instances_status = "STABLE"

  version {
    name              = local.application_version
    instance_template = google_compute_instance_template.application.self_link
  }

  dynamic "named_port" {
    for_each = var.application_ports

    content {
      name = named_port.value.name
      port = named_port.value.port
    }
  }

  dynamic "auto_healing_policies" {
    for_each = try([google_compute_health_check.port["http"].self_link], [])

    content {
      initial_delay_sec = local.application_ports_by_name["http"].health_check.initial_delay_sec

      health_check = auto_healing_policies.value
    }
  }

  update_policy {
    type           = "PROACTIVE"
    minimal_action = "RESTART"

    max_unavailable_fixed = 1
    max_surge_fixed       = max(1, var.scaling_horizontal_replicas - 1)
  }

  timeouts {
    create = "20m"
    update = "30m"
    delete = "20m"
  }

  depends_on = [
    google_compute_instance_template.application
  ]
}

# Define a security policy which allows to filter traffic by IP address,
# an edge security policy can also detect and block common types of web attacks
resource "google_compute_security_policy" "default" {
  project = var.project_id

  name = local.application_name

  type = "CLOUD_ARMOR"

  rule {
    action   = "allow"
    priority = "2147483647"

    match {
      versioned_expr = "SRC_IPS_V1"

      config {
        src_ip_ranges = ["*"]
      }
    }

    description = "default allow rule"
  }

  # TODO: Configure more WAF rules

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
  for_each = local.application_ports_by_name

  project = var.project_id

  name = "${local.application_name}-backend-${each.value.name}"

  load_balancing_scheme = "EXTERNAL"

  port_name = each.value.name
  protocol  = "HTTP"

  timeout_sec                     = 86400
  connection_draining_timeout_sec = 120

  enable_cdn       = false
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

  security_policy = google_compute_security_policy.default.self_link

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
  project = var.project_id

  name = local.application_name

  min_tls_version = "TLS_1_2"
  profile         = "MODERN"

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
}

## Create URL map for the application
resource "google_compute_url_map" "default" {
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
  project = var.project_id

  name = "${local.application_name}-http"

  url_map = google_compute_url_map.https_redirect.self_link
}

resource "google_compute_target_https_proxy" "default" {
  project = var.project_id

  name = "${local.application_name}-https"

  url_map = google_compute_url_map.default.self_link

  ssl_certificates = [google_compute_managed_ssl_certificate.default.self_link]
  ssl_policy       = google_compute_ssl_policy.application.self_link
  quic_override    = "NONE"
}

# Allocate global addresses for the load balancer and set up forwarding rules
## IPv4
resource "google_compute_global_address" "ipv4" {
  project = var.project_id

  name = "${local.application_name}-ipv4"

  ip_version = "IPV4"

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

resource "google_compute_global_forwarding_rule" "http" {
  project = var.project_id

  name   = local.application_name
  labels = local.application_labels

  target     = google_compute_target_http_proxy.default.self_link
  ip_address = google_compute_global_address.ipv4.address
  port_range = "80"

  load_balancing_scheme = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "https" {
  project = var.project_id

  name   = "${local.application_name}-https"
  labels = local.application_labels

  target     = google_compute_target_https_proxy.default.self_link
  ip_address = google_compute_global_address.ipv4.address
  port_range = "443"

  load_balancing_scheme = "EXTERNAL"
}

## IPv6
resource "google_compute_global_address" "ipv6" {
  project = var.project_id

  name = "${local.application_name}-ipv6"

  ip_version = "IPV6"

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

resource "google_compute_global_forwarding_rule" "http_ipv6" {
  project = var.project_id

  name   = "${local.application_name}-ipv6-http"
  labels = local.application_labels

  target     = google_compute_target_http_proxy.default.self_link
  ip_address = google_compute_global_address.ipv6.address
  port_range = "80"

  load_balancing_scheme = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "https_ipv6" {
  project = var.project_id

  name   = "${local.application_name}-ipv6-https"
  labels = local.application_labels

  target     = google_compute_target_https_proxy.default.self_link
  ip_address = google_compute_global_address.ipv6.address
  port_range = "443"

  load_balancing_scheme = "EXTERNAL"
}

## Open HTTP(S) ports for the load balancer
resource "google_compute_firewall" "http" {
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

## Open HTTP(S) ports for the health checks
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

# Create DNS records for the application
resource "google_dns_record_set" "application-ipv4" {
  project = var.project_id

  name = "${var.application_dns_tld}."
  type = "A"
  ttl  = 300

  managed_zone = var.dns_managed_zone_name

  rrdatas = [
    google_compute_global_address.ipv4.address
  ]

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

resource "google_dns_record_set" "application-ipv6" {
  project = var.project_id

  name = "${var.application_dns_tld}."
  type = "AAAA"
  ttl  = 300

  managed_zone = var.dns_managed_zone_name

  rrdatas = [
    google_compute_global_address.ipv6.address
  ]

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}
