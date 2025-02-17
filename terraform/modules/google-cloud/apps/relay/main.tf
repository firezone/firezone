locals {
  application_name    = var.application_name != null ? var.application_name : var.image
  application_version = var.application_version != null ? var.application_version : var.image_tag

  application_labels = merge({
    managed_by  = "terraform"
    application = local.application_name
  }, var.application_labels)

  google_health_check_ip_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16"
  ]

  environment_variables = concat([
    {
      name  = "LISTEN_ADDRESS_DISCOVERY_METHOD"
      value = "gce_metadata"
    },
    {
      name  = "OTEL_METADATA_DISCOVERY_METHOD"
      value = "gce_metadata"
    },
    {
      name  = "RUST_LOG"
      value = var.observability_log_level
    },
    {
      name  = "RUST_BACKTRACE"
      value = "full"
    },
    {
      name  = "LOG_FORMAT"
      value = "google-cloud"
    },
    {
      name  = "GOOGLE_CLOUD_PROJECT_ID"
      value = var.project_id
    },
    {
      name  = "OTLP_GRPC_ENDPOINT"
      value = "127.0.0.1:4317"
    },
    {
      name  = "FIREZONE_TOKEN"
      value = var.token
    },
    {
      name  = "FIREZONE_API_URL"
      value = var.api_url
    }
  ], var.application_environment_variables)
}

# Fetch most recent COS image
data "google_compute_image" "coreos" {
  family  = "cos-113-lts"
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


resource "google_compute_reservation" "relay_reservation" {
  for_each = var.instances

  project = var.project_id

  name = "relays-${element(each.value.zones, length(each.value.zones) - 1)}-${each.value.type}"
  zone = element(each.value.zones, length(each.value.zones) - 1)

  specific_reservation_required = true

  specific_reservation {
    count = each.value.replicas

    instance_properties {
      machine_type = each.value.type
    }
  }
}

# Deploy app
resource "google_compute_instance_template" "application" {
  for_each = var.instances

  project = var.project_id

  name_prefix = "${local.application_name}-${each.key}-${var.naming_suffix}-"

  description = "This template is used to create ${local.application_name} instances using Terraform."

  machine_type = each.value.type

  can_ip_forward = false

  tags = ["app-${local.application_name}"]

  labels = merge({
    container-vm = data.google_compute_image.coreos.name
    version      = local.application_version
  }, local.application_labels)

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  reservation_affinity {
    type = "SPECIFIC_RESERVATION"

    specific_reservation {
      key    = "compute.googleapis.com/reservation-name"
      values = ["relays-${element(each.value.zones, length(each.value.zones) - 1)}-${each.value.type}"]
    }
  }

  disk {
    source_image = data.google_compute_image.coreos.self_link
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = var.instances[each.key].subnet

    stack_type = "IPV4_IPV6"

    ipv6_access_config {
      network_tier = "PREMIUM"
      # Ephemeral IP address
    }

    access_config {
      network_tier = "PREMIUM"
      # Ephemeral IP address
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
    gce-container-declaration = yamlencode({
      spec = {
        containers = [{
          name  = local.application_name != null ? local.application_name : var.image
          image = "${var.container_registry}/${var.image_repo}/${var.image}:${var.image_tag}"
          env   = local.environment_variables
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
    google_compute_reservation.relay_reservation,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# Create health checks for the application ports
resource "google_compute_health_check" "port" {
  project = var.project_id

  name = "${local.application_name}-${var.health_check.name}"

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
  for_each = var.instances

  project = var.project_id

  name = "${local.application_name}-group-${each.key}-${var.naming_suffix}"

  base_instance_name = local.application_name

  region                    = each.key
  distribution_policy_zones = each.value.zones

  target_size = each.value.replicas

  wait_for_instances        = true
  wait_for_instances_status = "STABLE"

  version {
    name              = local.application_version
    instance_template = google_compute_instance_template.application[each.key].self_link
  }

  named_port {
    name = "stun"
    port = 3478
  }

  auto_healing_policies {
    initial_delay_sec = var.health_check.initial_delay_sec

    health_check = google_compute_health_check.port.self_link
  }

  update_policy {
    type           = "PROACTIVE"
    minimal_action = "REPLACE"

    # For all regions we need to take one replica down first because the reservation
    # won't allow to create surge instances
    # max_unavailable_fixed = each.value.replicas == 1 ? 0 : 1
    max_unavailable_fixed = 1

    # Reservations won't allow surge instances
    # max_surge_fixed       = max(length(each.value.zones), each.value.replicas - 1)
    max_surge_fixed = 0
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

# TODO: Rate limit requests to the relays by source IP address

# Open ports for STUN and TURN
resource "google_compute_firewall" "stun-turn-ipv4" {
  project = var.project_id

  name    = "${local.application_name}-firewall-lb-to-instances-ipv4"
  network = var.network

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["app-${local.application_name}"]

  allow {
    protocol = "udp"
    ports    = ["3478", "49152-65535"]
  }
}

resource "google_compute_firewall" "stun-turn-ipv6" {
  project = var.project_id

  name    = "${local.application_name}-firewall-lb-to-instances-ipv6"
  network = var.network

  source_ranges = ["::/0"]
  target_tags   = ["app-${local.application_name}"]

  allow {
    protocol = "udp"
    ports    = ["3478", "49152-65535"]
  }
}

## Open metrics port for the health checks
resource "google_compute_firewall" "http-health-checks" {
  project = var.project_id

  name    = "${local.application_name}-healthcheck"
  network = var.network

  source_ranges = local.google_health_check_ip_ranges
  target_tags   = ["app-${local.application_name}"]

  allow {
    protocol = var.health_check.protocol
    ports    = [var.health_check.port]
  }
}

# Allow outbound traffic
resource "google_compute_firewall" "egress-ipv4" {
  project = var.project_id

  name      = "${local.application_name}-egress-ipv4"
  network   = var.network
  direction = "EGRESS"

  target_tags        = ["app-${local.application_name}"]
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "egress-ipv6" {
  project = var.project_id

  name      = "${local.application_name}-egress-ipv6"
  network   = var.network
  direction = "EGRESS"

  target_tags        = ["app-${local.application_name}"]
  destination_ranges = ["::/0"]

  allow {
    protocol = "all"
  }
}
