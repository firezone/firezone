locals {
  application_name    = var.application_name != null ? var.application_name : var.image
  application_version = var.application_version != null ? var.application_version : var.image_tag

  application_labels = merge({
    managed_by  = "terraform"
    application = local.application_name
  }, var.application_labels)

  application_tags = ["app-${local.application_name}"]

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
    },
    {
      name  = "FIREZONE_ENABLE_MASQUERADE"
      value = "1"
    }
  ], var.application_environment_variables)
}

# Fetch most recent COS image
data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

# Deploy app
resource "google_compute_instance_template" "application" {
  project = var.project_id

  name_prefix = "${local.application_name}-"

  description = "This template is used to create ${local.application_name} instances."

  machine_type = var.compute_instance_type

  can_ip_forward = true

  tags = local.application_tags

  labels = merge({
    container-vm = data.google_compute_image.ubuntu.name
    version      = local.application_version
  }, local.application_labels)

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  disk {
    source_image = data.google_compute_image.ubuntu.self_link
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = var.compute_subnetwork

    stack_type = "IPV4_IPV6"

    ipv6_access_config {
      network_tier = "PREMIUM"
      # Ephimerical IP address
    }

    access_config {
      network_tier = "PREMIUM"
      # Ephimerical IP address
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
      container_name        = local.application_name != null ? local.application_name : var.image
      container_image       = "${var.container_registry}/${var.image_repo}/${var.image}:${var.image_tag}"
      container_environment = local.environment_variables
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

# # Create health checks for the application ports
# resource "google_compute_health_check" "port" {
#   project = var.project_id

#   name = "${local.application_name}-${var.health_check.name}"

#   check_interval_sec  = var.health_check.check_interval_sec != null ? var.health_check.check_interval_sec : 5
#   timeout_sec         = var.health_check.timeout_sec != null ? var.health_check.timeout_sec : 5
#   healthy_threshold   = var.health_check.healthy_threshold != null ? var.health_check.healthy_threshold : 2
#   unhealthy_threshold = var.health_check.unhealthy_threshold != null ? var.health_check.unhealthy_threshold : 2

#   log_config {
#     enable = false
#   }

#   http_health_check {
#     port = var.health_check.port

#     host         = var.health_check.http_health_check.host
#     request_path = var.health_check.http_health_check.request_path
#     response     = var.health_check.http_health_check.response
#   }

#   lifecycle {
#     create_before_destroy = true
#   }
# }

# Use template to deploy zonal instance group
resource "google_compute_region_instance_group_manager" "application" {
  project = var.project_id

  name = "${local.application_name}-${var.compute_region}"

  base_instance_name = local.application_name

  region                    = var.compute_region
  distribution_policy_zones = var.compute_instance_availability_zones

  target_size = var.compute_instance_replicas

  wait_for_instances        = true
  wait_for_instances_status = "STABLE"

  version {
    name              = local.application_version
    instance_template = google_compute_instance_template.application.self_link
  }

  # named_port {
  #   name = "stun"
  #   port = 3478
  # }

  # auto_healing_policies {
  #   initial_delay_sec = var.health_check.initial_delay_sec

  #   health_check = google_compute_health_check.port.self_link
  # }

  update_policy {
    type           = "PROACTIVE"
    minimal_action = "REPLACE"

    max_unavailable_fixed = 1
    max_surge_fixed       = max(1, var.compute_instance_replicas - 1)
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

# ## Open metrics port for the health checks
# resource "google_compute_firewall" "http-health-checks" {
#   project = var.project_id

#   name    = "${local.application_name}-healthcheck"
#   network = var.compute_network

#   source_ranges = local.google_health_check_ip_ranges
#   target_tags   = ["app-${local.application_name}"]

#   allow {
#     protocol = var.health_check.protocol
#     ports    = [var.health_check.port]
#   }
# }
