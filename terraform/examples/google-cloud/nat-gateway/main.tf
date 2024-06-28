module "gateway_gcp_example" {
  source = "github.com/firezone/firezone/terraform/modules/google-cloud/apps/gateway-region-instance-group"
  # If you are changing this example along with the module, you should use the local path:
  # source = "../../../modules/google-cloud/apps/gateway-region-instance-group"

  project_id = var.project_id

  compute_network    = google_compute_network.firezone.id
  compute_subnetwork = google_compute_subnetwork.firezone.id

  compute_instance_replicas = var.replicas
  compute_instance_type     = var.machine_type
  compute_region            = var.region

  # Since we are behind a NAT gateway, we don't need public IP addresses
  # to be automatically provisioned for the instances
  compute_provision_public_ipv6_address = false
  compute_provision_public_ipv4_address = false

  vsn = "latest"

  observability_log_level = "info"

  token = var.token
}

################################################################################
## Google Cloud Project
################################################################################

variable "project_id" {
  type        = string
  description = "Google Cloud Project ID"
}

################################################################################
## Compute
################################################################################

variable "region" {
  type        = string
  description = "Region to deploy the Gateway(s) in."
}

variable "replicas" {
  type        = number
  description = "Number of Gateway replicas to deploy in the availability zone."
  default     = 3
}

variable "machine_type" {
  type    = string
  default = "n1-standard-1"
}

################################################################################
## Observability
################################################################################

variable "log_level" {
  type     = string
  nullable = false
  default  = "info"

  description = "Sets RUST_LOG environment variable to configure the Gateway's log level. Default: 'info'."
}

################################################################################
## Firezone
################################################################################

variable "token" {
  type        = string
  description = "Gateway token to use for authentication."
}

variable "subnet_cidr" {
  type        = string
  description = "CIDR Range to use for subnet where Gateway(s) are deployed"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_project_service" "compute-api" {
  project = var.project_id
  service = "compute.googleapis.com"
}

resource "google_service_account" "firezone" {
  account_id   = "firezone-gateway"
  display_name = "Firezone Gateway Service Account"
}

# We create a new network and subnetwork. In real-world scenarios,
# you would likely use an existing ones where your application is deployed.
resource "google_compute_network" "firezone" {
  name                     = "firezone-gateway"
  auto_create_subnetworks  = false
  enable_ula_internal_ipv6 = true
  depends_on               = [google_project_service.compute-api]
}

resource "google_compute_subnetwork" "firezone" {
  project = var.project_id

  name = "firezone-gateways"

  stack_type = "IPV4_IPV6"

  ip_cidr_range = var.subnet_cidr
  region        = var.region
  network       = google_compute_network.firezone.id

  ipv6_access_type = "INTERNAL"

  private_ip_google_access = true
}

# Allocate IPv4 addresses for the NAT gateway
resource "google_compute_address" "ipv4" {
  project    = var.project_id
  name       = "firezone-gateway-nat-ipv4"
  ip_version = "IPV4"
}

# Create a router and NAT to allow outbound traffic
resource "google_compute_router" "firezone" {
  name    = "firezone-gateway-router"
  network = google_compute_network.firezone.id
}

resource "google_compute_router_nat" "firezone" {
  name   = "firezone-gateway-nat"
  router = google_compute_router.firezone.name

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips = [
    google_compute_address.ipv4.self_link,
  ]

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.firezone.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# Configure Firewall to allow outbound traffic
resource "google_compute_firewall" "gateways-egress-ipv4" {
  project = var.project_id

  name      = "firezone-gateways-egress-ipv4"
  network   = google_compute_network.firezone.id
  direction = "EGRESS"

  target_tags        = module.gateways.target_tags
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "gateways-egress-ipv6" {
  project = var.project_id

  name      = "firezone-gateways-egress-ipv6"
  network   = google_compute_network.firezone.id
  direction = "EGRESS"

  target_tags        = module.gateways.target_tags
  destination_ranges = ["::/0"]

  allow {
    protocol = "all"
  }
}

# Allow SSH access to the gateways. This is optional but helpful for debugging
# and administration of the gateways. Since they're not publicly accessible,
# you need to tunnel through IAP:
#
#   gcloud compute instances list --project <PROJECT_ID>
#   gcloud compute ssh --tunnel-through-iap --project <PROJECT_ID> gateway-XXXX
resource "google_compute_firewall" "ssh-rule" {
  name    = "allow-gateways-ssh"
  network = google_compute_network.firezone.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags   = module.gateways.target_tags
  source_ranges = ["35.235.240.0/20"] // IAP CIDR
}

output "static_ip_addresses" {
  value = [google_compute_address.ipv4.address]
}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "5.20"
    }
  }
}
