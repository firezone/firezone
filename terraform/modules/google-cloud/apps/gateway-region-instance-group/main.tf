data "google_compute_zones" "in_region" {
  project = var.project_id
  region  = var.compute_region
}

locals {
  labels = merge({
    managed_by  = "terraform"
    application = "firezone-gateway"
  }, var.labels)

  network_tags = [
    "firezone-gateways-${var.name}"
  ]

  google_health_check_ip_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]

  compute_region_zones = length(var.compute_instance_availability_zones) == 0 ? data.google_compute_zones.in_region.names : var.compute_instance_availability_zones
}

# Fetch most recent COS image
data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

# Deploy app
resource "google_compute_instance_template" "application" {
  project = var.project_id

  name_prefix = "${var.name}-"

  description = "This template is used to create ${var.name} Firezone Gateway instances."

  machine_type = var.compute_instance_type

  can_ip_forward = true

  tags = local.network_tags

  labels = merge({
    container-vm = data.google_compute_image.ubuntu.name
    version      = replace(var.vsn, ".", "-")
  }, local.labels)

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  reservation_affinity {
    type = "ANY_RESERVATION"
  }

  disk {
    source_image = data.google_compute_image.ubuntu.self_link
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = var.compute_subnetwork

    stack_type = "IPV4_IPV6"

    dynamic "ipv6_access_config" {
      for_each = var.compute_provision_public_ipv6_address == true ? [true] : []

      content {
        network_tier = "PREMIUM"
        # Ephemeral IP address
      }
    }

    dynamic "access_config" {
      for_each = var.compute_provision_public_ipv4_address == true ? [true] : []

      content {
        network_tier = "PREMIUM"
        # Ephemeral IP address
      }
    }
  }

  service_account {
    email = google_service_account.application.email

    scopes = [
      # Those are default scopes
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }

  metadata = {
    user-data = templatefile("${path.module}/templates/cloud-init.yaml", {
      project_id              = var.project_id
      otlp_grpc_endpoint      = "127.0.0.1:4317"
      observability_log_level = var.observability_log_level

      firezone_token        = var.token
      firezone_api_url      = var.api_url
      firezone_version      = var.vsn
      firezone_artifact_url = "https://storage.googleapis.com/firezone-prod-artifacts/firezone-gateway"
    })

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

# Create health check
resource "google_compute_health_check" "port" {
  project = var.project_id

  name = "${var.name}-${var.health_check.name}"

  check_interval_sec  = var.health_check.check_interval_sec != null ? var.health_check.check_interval_sec : 5
  timeout_sec         = var.health_check.timeout_sec != null ? var.health_check.timeout_sec : 5
  healthy_threshold   = var.health_check.healthy_threshold != null ? var.health_check.healthy_threshold : 2
  unhealthy_threshold = var.health_check.unhealthy_threshold != null ? var.health_check.unhealthy_threshold : 2

  log_config {
    enable = false
  }

  http_health_check {
    port = var.health_check.port

    host         = var.health_check.http_health_check.host
    request_path = var.health_check.http_health_check.request_path
    response     = var.health_check.http_health_check.response
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Use template to deploy zonal instance group
resource "google_compute_region_instance_group_manager" "application" {
  project = var.project_id

  name = "${var.name}-${var.compute_region}"

  base_instance_name = var.name

  region                    = var.compute_region
  distribution_policy_zones = local.compute_region_zones

  target_size = var.compute_instance_replicas

  wait_for_instances        = true
  wait_for_instances_status = "STABLE"

  version {
    name              = var.vsn
    instance_template = google_compute_instance_template.application.self_link
  }

  auto_healing_policies {
    initial_delay_sec = var.health_check.initial_delay_sec

    health_check = google_compute_health_check.port.self_link
  }

  update_policy {
    type           = "PROACTIVE"
    minimal_action = "REPLACE"

    max_unavailable_fixed = max(1, length(local.compute_region_zones))
    max_surge_fixed       = max(1, var.compute_instance_replicas - 1) + length(local.compute_region_zones)
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "20m"
  }

  depends_on = [
    google_compute_instance_template.application
  ]
}

## Open HTTP port for the health checks
resource "google_compute_firewall" "http-health-checks" {
  project = var.project_id

  name    = "${var.name}-healthcheck"
  network = var.compute_network

  source_ranges = local.google_health_check_ip_ranges
  target_tags   = local.network_tags

  allow {
    protocol = var.health_check.protocol
    ports    = [var.health_check.port]
  }
}
