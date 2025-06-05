locals {
  # IMPORTANT: Bump subnet numbering whenever changing any Relay instructure
  # to avoid numbering collisions due to the create_before_destroy lifecycle.
  subnet_ip_cidr_ranges = {
    "africa-south1"           = "10.241.0.0/24",
    "asia-east1"              = "10.241.1.0/24",
    "asia-east2"              = "10.241.2.0/24",
    "asia-northeast1"         = "10.241.3.0/24",
    "asia-northeast2"         = "10.241.4.0/24",
    "asia-northeast3"         = "10.241.5.0/24",
    "asia-south1"             = "10.241.6.0/24",
    "asia-south2"             = "10.241.7.0/24",
    "asia-southeast1"         = "10.241.8.0/24",
    "asia-southeast2"         = "10.241.9.0/24",
    "australia-southeast1"    = "10.241.10.0/24",
    "australia-southeast2"    = "10.241.11.0/24",
    "europe-central2"         = "10.241.12.0/24",
    "europe-north1"           = "10.241.13.0/24",
    "europe-southwest1"       = "10.241.14.0/24",
    "europe-west1"            = "10.241.15.0/24",
    "europe-west2"            = "10.241.16.0/24",
    "europe-west3"            = "10.241.17.0/24",
    "europe-west4"            = "10.241.18.0/24",
    "europe-west6"            = "10.241.19.0/24",
    "europe-west8"            = "10.241.20.0/24",
    "europe-west9"            = "10.241.21.0/24",
    "europe-west10"           = "10.241.22.0/24",
    "europe-west12"           = "10.241.23.0/24",
    "me-central1"             = "10.241.24.0/24",
    "me-west1"                = "10.241.25.0/24",
    "northamerica-northeast1" = "10.241.26.0/24",
    "northamerica-northeast2" = "10.241.27.0/24",
    "northamerica-south1"     = "10.241.28.0/24",
    "southamerica-east1"      = "10.241.29.0/24",
    "southamerica-west1"      = "10.241.30.0/24",
    "us-central1"             = "10.241.31.0/24",
    "us-east1"                = "10.241.32.0/24",
    "us-east4"                = "10.241.33.0/24",
    "us-east5"                = "10.241.34.0/24",
    "us-south1"               = "10.241.35.0/24",
    "us-west1"                = "10.241.36.0/24",
    "us-west2"                = "10.241.37.0/24",
    "us-west3"                = "10.241.38.0/24",
    "us-west4"                = "10.241.39.0/24"
  }
}

# GCP requires networks and subnets to have globally unique names.
# This causes an issue if their configuration changes because we
# use create_before_destroy to avoid downtime on deploys.
#
# To work around this, we use a random suffix in the name and rotate
# it whenever the subnet IP CIDR ranges change. It's not a perfect
# solution, but it should cover most cases.
resource "random_string" "naming_suffix" {
  length  = 8
  special = false
  upper   = false

  keepers = {
    # must be a string
    subnet_ip_cidr_ranges = jsonencode(local.subnet_ip_cidr_ranges)
  }
}

# Create networks
resource "google_compute_network" "network" {
  project = module.google-cloud-project.project.project_id
  name    = "relays-network-${random_string.naming_suffix.result}"

  routing_mode = "GLOBAL"

  auto_create_subnetworks = false

  depends_on = [
    google_project_service.compute
  ]

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_subnetwork" "subnetwork" {
  for_each = local.subnet_ip_cidr_ranges
  project  = module.google-cloud-project.project.project_id
  name     = "relays-subnet-${each.key}-${random_string.naming_suffix.result}"
  region   = each.key
  network  = google_compute_network.network.self_link

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    metadata             = "INCLUDE_ALL_METADATA"
  }

  stack_type = "IPV4_IPV6"

  # Sequentially numbered /24s given an offset
  ip_cidr_range            = each.value
  ipv6_access_type         = "EXTERNAL"
  private_ip_google_access = true

  lifecycle {
    create_before_destroy = true
  }
}

module "relays" {
  count      = var.relay_token != null ? 1 : 0
  source     = "../../modules/google-cloud/apps/relay"
  project_id = module.google-cloud-project.project.project_id

  # Remember to update the following published documentation when this changes:
  #  - /website/src/app/kb/deploy/gateways/readme.mdx
  #  - /website/src/app/kb/architecture/tech-stack/readme.mdx
  instances = {
    "africa-south1" = {
      subnet   = google_compute_subnetwork.subnetwork["africa-south1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["africa-south1-a"]
    }
    "asia-east1" = {
      subnet   = google_compute_subnetwork.subnetwork["asia-east1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["asia-east1-a"]
    }
    "asia-east2" = {
      subnet   = google_compute_subnetwork.subnetwork["asia-east2"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["asia-east2-a"]
    }
    "asia-northeast1" = {
      subnet   = google_compute_subnetwork.subnetwork["asia-northeast1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["asia-northeast1-a"]
    }
    "asia-northeast2" = {
      subnet   = google_compute_subnetwork.subnetwork["asia-northeast2"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["asia-northeast2-a"]
    }
    "asia-northeast3" = {
      subnet   = google_compute_subnetwork.subnetwork["asia-northeast3"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["asia-northeast3-a"]
    }
    "asia-south1" = {
      subnet   = google_compute_subnetwork.subnetwork["asia-south1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["asia-south1-a"]
    }
    "asia-south2" = {
      subnet   = google_compute_subnetwork.subnetwork["asia-south2"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["asia-south2-a"]
    }
    "asia-southeast1" = {
      subnet   = google_compute_subnetwork.subnetwork["asia-southeast1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["asia-southeast1-a"]
    }
    "asia-southeast2" = {
      subnet   = google_compute_subnetwork.subnetwork["asia-southeast2"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["asia-southeast2-a"]
    }
    "australia-southeast1" = {
      subnet   = google_compute_subnetwork.subnetwork["australia-southeast1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["australia-southeast1-a"]
    }
    "australia-southeast2" = {
      subnet   = google_compute_subnetwork.subnetwork["australia-southeast2"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["australia-southeast2-a"]
    }
    "europe-central2" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-central2"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-central2-a"]
    }
    "europe-north1" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-north1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-north1-a"]
    }
    "europe-southwest1" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-southwest1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-southwest1-a"]
    }
    "europe-west1" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-west1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-west1-b"]
    }
    "europe-west2" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-west2"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-west2-a"]
    }
    "europe-west3" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-west3"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-west3-a"]
    }
    "europe-west4" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-west4"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-west4-a"]
    }
    "europe-west6" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-west6"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-west6-a"]
    }
    "europe-west8" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-west8"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-west8-a"]
    }
    "europe-west9" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-west9"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-west9-a"]
    }
    "europe-west10" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-west10"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-west10-a"]
    }
    "europe-west12" = {
      subnet   = google_compute_subnetwork.subnetwork["europe-west12"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["europe-west12-a"]
    }
    "me-central1" = {
      subnet   = google_compute_subnetwork.subnetwork["me-central1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["me-central1-a"]
    }
    # Fails with:
    # Access to the region is unavailable. Please contact our sales team at https://cloud.google.com/contact for further assistance."
    # "me-central2" = {
    #   type       = "e2-custom-2-1024"
    #   replicas   = 1
    #   zones      = ["me-central2-a"]
    # }
    "me-west1" = {
      subnet   = google_compute_subnetwork.subnetwork["me-west1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["me-west1-a"]
    }
    "northamerica-northeast1" = {
      subnet   = google_compute_subnetwork.subnetwork["northamerica-northeast1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["northamerica-northeast1-a"]
    }
    "northamerica-northeast2" = {
      subnet   = google_compute_subnetwork.subnetwork["northamerica-northeast2"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["northamerica-northeast2-a"]
    }
    "northamerica-south1" = {
      subnet   = google_compute_subnetwork.subnetwork["northamerica-south1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["northamerica-south1-a"]
    }
    "southamerica-east1" = {
      subnet   = google_compute_subnetwork.subnetwork["southamerica-east1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["southamerica-east1-a"]
    }
    "southamerica-west1" = {
      subnet   = google_compute_subnetwork.subnetwork["southamerica-west1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["southamerica-west1-a"]
    }
    "us-central1" = {
      subnet   = google_compute_subnetwork.subnetwork["us-central1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["us-central1-a"]
    }
    "us-east1" = {
      subnet   = google_compute_subnetwork.subnetwork["us-east1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["us-east1-b"]
    }
    "us-east4" = {
      subnet   = google_compute_subnetwork.subnetwork["us-east4"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["us-east4-a"]
    }
    "us-east5" = {
      subnet   = google_compute_subnetwork.subnetwork["us-east5"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["us-east5-a"]
    }
    "us-south1" = {
      subnet   = google_compute_subnetwork.subnetwork["us-south1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["us-south1-a"]
    }
    "us-west1" = {
      subnet   = google_compute_subnetwork.subnetwork["us-west1"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["us-west1-a"]
    }
    "us-west2" = {
      subnet   = google_compute_subnetwork.subnetwork["us-west2"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["us-west2-a"]
    }
    "us-west3" = {
      subnet   = google_compute_subnetwork.subnetwork["us-west3"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["us-west3-a"]
    }
    "us-west4" = {
      subnet   = google_compute_subnetwork.subnetwork["us-west4"].self_link
      type     = "e2-custom-2-1024"
      replicas = 1
      zones    = ["us-west4-a"]
    }
  }
  network                 = google_compute_network.network.self_link
  naming_suffix           = random_string.naming_suffix.result
  container_registry      = module.google-artifact-registry.url
  image_repo              = module.google-artifact-registry.repo
  image                   = "relay"
  image_tag               = local.relay_image_tag
  observability_log_level = "info,hyper=off,h2=warn,tower=warn"
  application_name        = "relay"
  application_version     = replace(local.relay_image_tag, ".", "-")
  application_environment_variables = [
    {
      name  = "FIREZONE_TELEMETRY"
      value = "true"
    }
  ]
  health_check = {
    name                = "health"
    protocol            = "TCP"
    port                = 8080
    initial_delay_sec   = 60
    check_interval_sec  = 15
    timeout_sec         = 10
    healthy_threshold   = 1
    unhealthy_threshold = 3
    http_health_check = {
      request_path = "/healthz"
    }
  }
  api_url = "wss://api.${local.tld}"
  token   = var.relay_token
}
