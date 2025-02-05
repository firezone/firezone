# Deploy our dogfood gateways
locals {
  gateways_region         = local.region
  gateways_zone           = local.availability_zone
  gateways_instance_type  = "e2-micro"
  gateways_instance_count = 2
}

# Reserve instances for the gateway
# If you don't reserve them deployment takes much longer and there is no guarantee that instances will be created at all,
# Google Cloud Platform does not guarantee that instances will be available when you need them.
resource "google_compute_reservation" "gateways_reservation" {
  project = module.google-cloud-project.project.project_id

  name = "gateways-${local.availability_zone}-${local.gateways_instance_type}"
  zone = local.gateways_zone

  specific_reservation {
    count = local.gateways_instance_count

    instance_properties {
      machine_type = local.gateways_instance_type
    }
  }
}

module "gateways" {
  count = var.gateway_token != null ? 1 : 0

  source     = "../../modules/google-cloud/apps/gateway-region-instance-group"
  project_id = module.google-cloud-project.project.project_id

  compute_network    = module.google-cloud-vpc.id
  compute_subnetwork = google_compute_subnetwork.tools.self_link

  compute_instance_type               = local.gateways_instance_type
  compute_region                      = local.gateways_region
  compute_instance_availability_zones = [local.gateways_zone]

  compute_instance_replicas = local.gateways_instance_count

  observability_log_level = "info"

  name    = "gateway"
  api_url = "wss://api.${local.tld}"
  token   = var.gateway_token

  vsn = local.gateway_image_tag

  depends_on = [
    google_compute_reservation.gateways_reservation
  ]
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
    protocol = "all"
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
    protocol = "all"
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

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }

  # Only allows connections using IAP
  source_ranges = local.iap_ipv4_ranges
  target_tags   = module.gateways[0].target_tags
}
