# Deploy our dogfood gateways
locals {
  gateways_region = local.region
  gateways_zones  = [local.availability_zone]
}

module "gateways" {
  count = var.gateway_token != null ? 1 : 0

  source     = "../../modules/gateway-google-cloud-compute"
  project_id = module.google-cloud-project.project.project_id

  compute_network    = module.google-cloud-vpc.id
  compute_subnetwork = google_compute_subnetwork.tools.self_link

  compute_instance_type               = "n1-standard-1"
  compute_region                      = local.gateways_region
  compute_instance_availability_zones = local.gateways_zones

  compute_instance_replicas = 2

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "gateway"
  image_tag  = var.image_tag

  observability_log_level = "debug"

  application_name    = "gateway"
  application_version = replace(var.image_tag, ".", "-")

  health_check = {
    name     = "health"
    protocol = "TCP"
    port     = 8080

    initial_delay_sec = 60

    check_interval_sec  = 15
    timeout_sec         = 10
    healthy_threshold   = 1
    unhealthy_threshold = 3

    http_health_check = {
      request_path = "/healthz"
    }
  }

  api_url = "wss://api.${local.tld}"
  token   = var.gateway_token
}

# Allow gateways to access the Metabase
resource "google_compute_firewall" "gateways-metabase-access" {
  count = var.gateway_token != null ? 1 : 0

  project = module.google-cloud-project.project.project_id

  name      = "gateways-metabase-access"
  network   = module.google-cloud-vpc.id
  direction = "INGRESS"

  source_tags = module.gateways[0].target_tags
  target_tags = module.metabase.target_tags

  allow {
    protocol = "tcp"
  }
}

# curl "http://metabase.c.firezone-prod.internal:3000/" -v

# Allow outbound traffic
resource "google_compute_firewall" "gateways-egress-ipv4" {
  count = var.gateway_token != null ? 1 : 0

  project = module.google-cloud-project.project.project_id

  name      = "gateways-egress-ipv4"
  network   = module.google-cloud-vpc.id
  direction = "EGRESS"

  target_tags        = module.gateways[0].target_tags
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "udp"
  }
}

resource "google_compute_firewall" "gateways-egress-ipv6" {
  count = var.gateway_token != null ? 1 : 0

  project = module.google-cloud-project.project.project_id

  name      = "gateways-egress-ipv6"
  network   = module.google-cloud-vpc.id
  direction = "EGRESS"

  target_tags        = module.gateways[0].target_tags
  destination_ranges = ["::/0"]

  allow {
    protocol = "udp"
  }
}

resource "google_compute_firewall" "gateways-ssh-ipv4" {
  count = length(module.gateways) > 0 ? 1 : 0

  project = module.google-cloud-project.project.project_id

  name    = "gateways-ssh-ipv4"
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
  target_tags   = module.gateways[0].target_tags
}
