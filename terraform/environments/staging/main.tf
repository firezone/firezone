locals {
  project_owners = [
    "bmanifold@firezone.dev",
    "jamil@firezone.dev",
    "thomas@firezone.dev",
  ]

  # list of emails for users that should be able to SSH into a demo instance
  demo_access = []

  region            = "us-east1"
  availability_zone = "us-east1-d"

  tld = "firez.one"

  # This is GitHub Actions service account configured manually
  # in the project github-iam-387915
  ci_iam_members = [
    "serviceAccount:github-actions@github-iam-387915.iam.gserviceaccount.com"
  ]

  iap_ipv4_ranges = [
    "35.235.240.0/20"
  ]
}

terraform {
  cloud {
    organization = "firezone"
    hostname     = "app.terraform.io"

    workspaces {
      name = "staging"
    }
  }
}

provider "random" {}
provider "null" {}
provider "google" {}
provider "google-beta" {}

# Create the project
module "google-cloud-project" {
  source = "../../modules/google-cloud/project"

  id                    = "firezone-staging"
  name                  = "Staging Environment"
  organization_id       = "335836213177"
  billing_account_id    = "01DFC9-3D6951-579BE1"
  billing_budget_amount = var.billing_budget_amount

  auto_create_network = false
}

# Grant owner access to the project
resource "google_project_iam_binding" "project_owners" {
  project = module.google-cloud-project.project.project_id
  role    = "roles/owner"
  members = formatlist("user:%s", local.project_owners)
}

# Grant GitHub Actions ability to write to the container registry
module "google-artifact-registry" {
  source = "../../modules/google-cloud/artifact-registry"

  project_id   = module.google-cloud-project.project.project_id
  project_name = module.google-cloud-project.name

  region = local.region

  store_tagged_artifacts_for   = "${90 * 24 * 60 * 60}s"
  store_untagged_artifacts_for = "${90 * 24 * 60 * 60}s"

  writers = local.ci_iam_members
}

# Create a VPC
module "google-cloud-vpc" {
  source = "../../modules/google-cloud/vpc"

  project_id = module.google-cloud-project.project.project_id
  name       = module.google-cloud-project.project.project_id

  nat_region = local.region
}

# Enable Google Cloud Storage for the project
module "google-cloud-storage" {
  source = "../../modules/google-cloud/storage"

  project_id = module.google-cloud-project.project.project_id
}

# Create DNS managed zone
module "google-cloud-dns" {
  source = "../../modules/google-cloud/dns"

  project_id = module.google-cloud-project.project.project_id

  tld            = local.tld
  dnssec_enabled = false
}

# Create the Cloud SQL database
module "google-cloud-sql" {
  source     = "../../modules/google-cloud/sql"
  project_id = module.google-cloud-project.project.project_id
  network    = module.google-cloud-vpc.id

  compute_region            = local.region
  compute_availability_zone = local.availability_zone

  compute_instance_cpu_count   = "2"
  compute_instance_memory_size = "7680"

  database_name = module.google-cloud-project.project.project_id

  database_highly_available = false
  database_backups_enabled  = false

  database_read_replica_locations = []

  database_flags = {
    # Increase the connections count a bit, but we need to set it to Ecto ((pool_count * pool_size) + 50)
    "max_connections" = "500"

    # Sets minimum threshold on dead tuples to prevent autovaccum running too often on small tables
    # where 5% is less than 50 records
    "autovacuum_vacuum_threshold" = "50"

    # Trigger autovaccum for every 5% of the table changed
    "autovacuum_vacuum_scale_factor"  = "0.05"
    "autovacuum_analyze_scale_factor" = "0.05"

    # Give autovacuum 4x the cost limit to prevent it from never finishing
    # on big tables
    "autovacuum_vacuum_cost_limit" = "800"

    # Give hash joins a bit more memory to work with
    # "hash_mem_multiplier" = "3"

    # This is standard value for work_mem
    "work_mem" = "4096"
  }
}

# Enable SSH on staging
resource "google_compute_firewall" "ssh-ipv4" {
  project = module.google-cloud-project.project.project_id

  name    = "ssh-ipv4"
  network = module.google-cloud-vpc.self_link

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

  source_ranges = ["0.0.0.0/0"]
  target_tags = concat(
    module.web.target_tags,
    module.api.target_tags,
    module.domain.target_tags,
    length(module.relays) > 0 ? module.relays[0].target_tags : []
  )
}

resource "google_compute_firewall" "ssh-ipv6" {
  project = module.google-cloud-project.project.project_id

  name    = "ssh-ipv6"
  network = module.google-cloud-vpc.self_link

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

  source_ranges = ["::/0"]
  target_tags = concat(
    module.web.target_tags,
    module.api.target_tags,
    module.domain.target_tags
  )
}

module "ops" {
  source = "../../modules/google-cloud/ops"

  project_id = module.google-cloud-project.project.project_id

  slack_alerts_auth_token = var.slack_alerts_auth_token
  slack_alerts_channel    = var.slack_alerts_channel

  api_host = module.api.host
  web_host = module.web.host
}
