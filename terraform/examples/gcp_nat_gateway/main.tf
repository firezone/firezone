terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
      version = "5.19.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region    = var.region
  zone      = var.zone
}

resource "google_service_account" "firezone" {
  account_id   = "firezone-gateway"
  display_name = "Firezone Gateway Service Account"
}

resource "google_compute_subnetwork" "firezone" {
  name          = "firezone-gateway-subnet"
  ip_cidr_range = "10.99.0.0/16"
  region = var.region
  network = google_compute_network.firezone.id
  stack_type       = "IPV4_IPV6"
  ipv6_access_type = "EXTERNAL"
}

resource "google_compute_network" "firezone" {
  name = "firezone-gateway"
  auto_create_subnetworks = false
}

resource "google_compute_router" "firezone" {
  name    = "firezone-gateway-router"
  network = google_compute_network.firezone.id
}

resource "google_compute_router_nat" "firezone" {
  name            = "firezone-gateway-nat"
  router          = google_compute_router.firezone.name
  nat_ip_allocate_option = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_instance_template" "gateway" {
  name        = "gateway-template"
  description = "Instance template for the Firezone Gateway"
  instance_description = "Firezone Gateway"
  machine_type = var.machine_type
  tags        = ["gateway"]
  can_ip_forward = true

  scheduling {
    automatic_restart = true
    on_host_maintenance = "MIGRATE"
  }

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = google_compute_subnetwork.firezone.id
  }

  service_account {
    email  = google_service_account.firezone.email
    scopes = ["cloud-platform"]
  }

}

// Allow SSH access to the gateways. This is optional but helpful for debugging
// and administration of the gateways. Since they're not publicly accessible,
// you need to tunnel through IAP:
//
//   gcloud compute ssh --tunnel-through-iap --project <PROJECT_ID> --zone <ZONE> gateway-0
resource "google_compute_firewall" "ssh-rule" {
  name    = "allow-ssh"
  network = google_compute_network.firezone.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags = ["gateway"]
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_instance_from_template" "gateway" {
  name         = "gateway-${count.index}"
  count        = var.replicas
  source_instance_template = google_compute_instance_template.gateway.self_link_unique

  # Script is defined here to set instance-specific metadata
  metadata_startup_script = <<-SCRIPT
  #!/usr/bin/env bash
  set -euo pipefail

  # Install dependencies
  sudo apt-get update
  sudo apt-get install -y iptables curl

  # Set necessary environment variables
  FIREZONE_NAME="gateway-${count.index}"
  FIREZONE_ID="gateway-${google_cloud_subnetwork.firezone.id}-${count.index}"
  FIREZONE_TOKEN="${var.token}"
  FIREZONE_API_URL="wss://api.firezone.dev"
  RUST_LOG="${var.log_level}"

  # Install systemd unit file and start the gateway
  bash <(curl -fsSL https://raw.githubusercontent.com/firezone/firezone/main/scripts/gateway-systemd-install.sh)

  SCRIPT
}
