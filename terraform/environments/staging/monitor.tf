# Deploy our Firezone monitor instance

locals {
  client_monitor_region = local.region
  client_monitor_zone   = local.availability_zone
}

module "client_monitor" {
  source     = "../../modules/google-cloud/apps/client-monitor"
  project_id = module.google-cloud-project.project.project_id

  compute_network    = module.google-cloud-vpc.id
  compute_subnetwork = google_compute_subnetwork.apps.self_link

  compute_instance_type              = "f1-micro"
  compute_region                     = local.client_monitor_region
  compute_instance_availability_zone = local.client_monitor_zone

  container_registry = module.google-artifact-registry.url

  firezone_client_id = "gcp-client-monitor-main"
  firezone_api_url   = "wss://api.firez.one"
  firezone_token     = var.firezone_client_token

  image_repo = module.google-artifact-registry.repo
  image      = "client"
  image_tag  = var.image_tag

  application_name = "client-monitor"

  application_environment_variables = []

  health_check = {
    name     = "health"
    protocol = "TCP"
    port     = 3000

    initial_delay_sec = 60

    check_interval_sec  = 15
    timeout_sec         = 10
    healthy_threshold   = 1
    unhealthy_threshold = 3

    http_health_check = {
      request_path = "/healthz"
    }
  }
}

# Allow outbound traffic
resource "google_compute_firewall" "client-monitor-egress-ipv4" {
  project = module.google-cloud-project.project.project_id

  name      = "client-monitor-egress-ipv4"
  network   = module.google-cloud-vpc.id
  direction = "EGRESS"

  target_tags        = module.client_monitor.target_tags
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "client-monitor-ssh-ipv4" {
  project = module.google-cloud-project.project.project_id

  name    = "client-monitor-ssh-ipv4"
  network = module.google-cloud-vpc.id

  allow {
    protocol = "tcp"
    ports    = [22]
  }

  allow {
    protocol = "udp"
    ports    = [22]
  }

  allow {
    protocol = "sctp"
    ports    = [22]
  }

  # Only allows connections using IAP
  source_ranges = local.iap_ipv4_ranges
  target_tags   = module.client_monitor.target_tags
}
