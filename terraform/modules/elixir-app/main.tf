locals {
  application_name    = var.application_name != null ? var.application_name : var.image
  application_version = var.application_version != null ? var.application_version : var.image_tag

  application_labels = merge({
    managed_by  = "terraform"
    application = local.application_name
    version     = local.application_version
  }, var.application_labels)

  application_environment_variables = concat([
    {
      name  = "RELEASE_HOST_DISCOVERY_METHOD"
      value = "gce_metadata"
    }
  ], var.application_environment_variables)
}

# Fetch most recent COS image
data "google_compute_image" "coreos" {
  family  = "cos-105-lts"
  project = "cos-cloud"
}

# # Reserve static IP address for the application instances
# resource "google_compute_address" "app-ip" {
#   count = var.scaling_horizontal_replicas

#   project = var.project_id

#   name   = "app-ip"
#   region = var.region
# }

# Create IAM role for the application instances
resource "google_service_account" "application" {
  project = var.project_id

  account_id   = "app-${local.application_name}"
  display_name = "${local.application_name} app"
  description  = "Service account for ${local.application_name} application instances."
}

# Allow application service account to pull images from the container registry
resource "google_project_iam_binding" "application" {
  project = var.project_id

  role = "roles/artifactregistry.reader"

  members = ["serviceAccount:${google_service_account.application.email}"]
}

# Deploy the app
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
  }

  service_account {
    email = google_service_account.application.email

    # Those are copying gke-default scopes
    scopes = [
      "storage-ro",
      "logging-write",
      "monitoring",
      "service-management",
      "service-control",
      "trace",
    ]
  }

  metadata = merge({
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

    # Enable FluentBit agent for logging, which will be default one from COS 109
    google-logging-enabled       = "true"
    google-logging-use-fluentbit = "true"

    # Report health-related metrics to Cloud Monitoring
    google-monitoring-enabled = "true"
  })

  depends_on = [
    google_project_service.compute,
    google_project_service.pubsub,
    google_project_service.bigquery,
    google_project_service.container,
    google_project_service.stackdriver,
    google_project_service.logging,
    google_project_service.monitoring,
    google_project_service.clouddebugger,
    google_project_service.cloudprofiler,
    google_project_service.cloudtrace,
    google_project_service.servicenetworking,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# TODO: we want google_compute_region_instance_group_manager to provide HA-mode within region on production
resource "google_compute_instance_group_manager" "application" {
  provider = google-beta
  project  = var.project_id
  name     = "${local.application_name}-group"

  base_instance_name = local.application_name
  zone               = var.compute_instance_availability_zone != null ? "${var.compute_instance_availability_zone}" : var.compute_instance_region

  target_size = var.scaling_horizontal_replicas

  wait_for_instances        = true
  wait_for_instances_status = "STABLE"

  version {
    instance_template = google_compute_instance_template.application.self_link
  }

  # auto_healing_policies {
  #   health_check      = google_compute_health_check.application.self_link
  #   initial_delay_sec = 60
  # }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_unavailable_fixed = 1
  }

  depends_on = [
    google_compute_instance_template.application
  ]
}

# Open HTTP(S) ports for the application instances
resource "google_compute_firewall" "http" {
  project = var.project_id

  name    = "${local.application_name}-http"
  network = var.vpc_network

  allow {
    protocol = "tcp"
    ports    = [80, 443]
  }

  allow {
    protocol = "udp"
    ports    = [80, 443]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["app-${local.application_name}"]
}

# resource "google_compute_health_check" "application" {
#   name    = "application-health"
#   project = var.project_id

#   timeout_sec        = 30
#   check_interval_sec = 60

#   tcp_health_check {
#     port = var.application_port
#   }
# }
