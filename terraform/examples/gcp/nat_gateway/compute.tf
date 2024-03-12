resource "google_compute_instance_template" "gateway" {
  name                 = "gateway-template"
  description          = "Instance template for the Firezone Gateway"
  instance_description = "Firezone Gateway"
  machine_type         = var.machine_type
  tags                 = ["firezone-gateway"]
  can_ip_forward       = true

  scheduling {
    automatic_restart   = true
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

resource "google_compute_instance_from_template" "gateway" {
  name                     = "gateway-${count.index}"
  count                    = var.replicas
  source_instance_template = google_compute_instance_template.gateway.self_link_unique

  # Script is defined here to set instance-specific metadata
  metadata_startup_script = <<-SCRIPT
  #!/usr/bin/env bash
  set -euo pipefail

  # Install dependencies
  sudo apt-get update
  sudo apt-get install -y iptables curl

  # Set necessary environment variables and run installer
  FIREZONE_ID="gateway-${google_compute_instance_template.gateway.id}-${count.index}" \
    FIREZONE_TOKEN="${var.token}" \
    bash <(curl -fsSL https://raw.githubusercontent.com/firezone/firezone/main/scripts/gateway-systemd-install.sh)

  SCRIPT
}
