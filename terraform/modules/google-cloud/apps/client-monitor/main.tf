locals {
  application_name    = var.application_name
  application_version = var.application_version

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
      name  = "GOOGLE_CLOUD_PROJECT_ID"
      value = var.project_id
    }
  ], var.application_environment_variables)
}

# Find latest ubuntu 22.04 image
data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2204-lts"
  project = "ubuntu-os-cloud"
}

# Deploy app
resource "google_compute_address" "client_monitor" {
  project = var.project_id

  region     = var.compute_region
  name       = "firezone-monitor"
  subnetwork = var.compute_subnetwork

  address_type = "INTERNAL"
}

resource "google_compute_instance" "client_monitor" {
  project = var.project_id

  name        = local.application_name
  description = "This template is used to create ${local.application_name} instances."

  zone = var.compute_instance_availability_zone

  machine_type = var.compute_instance_type

  can_ip_forward = true

  tags = local.application_tags

  labels = merge({
    ubuntu-vm = data.google_compute_image.ubuntu.name
    version   = local.application_version
  }, local.application_labels)

  boot_disk {
    auto_delete = true

    initialize_params {
      image = data.google_compute_image.ubuntu.self_link

      labels = {
        managed_by = "terraform"
      }
    }
  }

  network_interface {
    subnetwork = var.compute_subnetwork
    stack_type = "IPV4_ONLY"
    network_ip = google_compute_address.client_monitor.address

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

  # us-east1-docker.pkg.dev/firezone-staging/firezone/client:1.0.0-3e457fbd3c9252ba4c5b7a7cc943bceae8c3c827
  metadata = {
    user-data = templatefile("${path.module}/templates/cloud-init.yaml", {
      client_container_image    = "${var.container_registry}/${var.image_repo}/${var.image}:${var.image_tag}"
      firezone_token            = var.firezone_token
      firezone_api_url          = var.firezone_api_url
      firezone_client_id        = var.firezone_client_id
      firezone_client_log_level = var.firezone_client_log_level
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
    google_project_iam_member.logs,
    google_project_iam_member.errors,
    google_project_iam_member.metrics,
    google_project_iam_member.service_management,
    google_project_iam_member.cloudtrace,
  ]

  allow_stopping_for_update = true
}

## Open metrics port for the health checks
resource "google_compute_firewall" "http-health-checks" {
  project = var.project_id

  name    = "${local.application_name}-healthcheck"
  network = var.compute_network

  source_ranges = local.google_health_check_ip_ranges
  target_tags   = ["app-${local.application_name}"]

  allow {
    protocol = var.health_check.protocol
    ports    = [var.health_check.port]
  }
}
