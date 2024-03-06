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

resource "google_service_account" "default" {
  account_id   = "firezone-gateway"
  display_name = "Firezone Gateway Service Account"
}

resource "google_compute_subnetwork" "default" {
  name          = "firezone-gateway-subnet"
  ip_cidr_range = "10.99.0.0/16"
  region = var.region
  network = google_compute_network.default.id
  stack_type       = "IPV4_IPV6"
  ipv6_access_type = "EXTERNAL"
}

resource "google_compute_network" "default" {
  name = "firezone-gateway"
  auto_create_subnetworks = false
}

resource "google_compute_router" "default" {
  name    = "firezone-gateway-router"
  network = google_compute_network.default.id
}

resource "google_compute_router_nat" "default" {
  name            = "firezone-gateway-nat"
  router          = google_compute_router.default.name
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
    subnetwork = google_compute_subnetwork.default.id
    stack_type = "IPV4_IPV6"
  }

  service_account {
    email  = google_service_account.default.email
    scopes = ["cloud-platform"]
  }
}

resource "google_compute_instance_from_template" "gateway" {
  name         = "gateway-${count.index}"
  count        = var.replicas
  source_instance_template = google_compute_instance_template.gateway.self_link_unique
}
