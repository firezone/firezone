locals {
  vm_name = var.vm_name

  vm_labels = merge({
    managed_by = "terraform"
  }, var.vm_labels)

  vm_network_tags = [var.vm_network_tag]

  google_health_check_ip_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16"
  ]
}

# Find the latest boot image
data "google_compute_image" "boot" {
  family  = var.boot_image_family
  project = var.boot_image_project
}

# Provision an internal IPv4 address for the VM
resource "google_compute_address" "ipv4" {
  project = var.project_id

  region     = var.compute_region
  name       = local.vm_name
  subnetwork = var.compute_subnetwork

  address_type = "INTERNAL"
}

resource "google_compute_instance" "vm" {
  project = var.project_id

  name        = local.vm_name
  description = "This template is used to create ${local.vm_name} instances."

  zone = var.compute_instance_availability_zone

  machine_type = var.compute_instance_type

  can_ip_forward = true

  tags = local.vm_network_tags

  labels = merge({
    boot_image_family  = var.boot_image_family
    boot_image_project = var.boot_image_project
  }, local.vm_labels)

  boot_disk {
    auto_delete = true

    initialize_params {
      image = data.google_compute_image.boot.self_link

      labels = {
        managed_by         = "terraform"
        boot_image_family  = var.boot_image_family
        boot_image_project = var.boot_image_project
      }
    }
  }

  network_interface {
    subnetwork = var.compute_subnetwork
    stack_type = "IPV4_ONLY"
    network_ip = google_compute_address.ipv4.address

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
    user-data = var.cloud_init

    # Report logs to Cloud Logging and errors to Cloud Error Reporting
    google-logging-enabled       = "true"
    google-logging-use-fluentbit = "true"

    # Report VM metrics to Cloud Monitoring
    google-monitoring-enabled = "true"
  }

  # Install the Ops Agent and some other tools that are helpful for debugging (curl, jq, etc.)
  metadata_startup_script = <<EOT
    set -xe \
      && sudo apt update -y \
      && sudo apt install -y apt-transport-https ca-certificates curl jq software-properties-common \
      && sudo install -m 0755 -d /etc/apt/keyrings \
      && sudo apt-get update \
      && curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh \
      && sudo bash add-google-cloud-ops-agent-repo.sh --also-install
EOT

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
