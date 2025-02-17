locals {
  project_owners = [
    "bmanifold@firezone.dev",
    "jamil@firezone.dev",
  ]

  region            = "us-east1"
  availability_zone = "us-east1-d"

  tld = "firezone.dev"

  iap_ipv4_ranges = [
    "35.235.240.0/20"
  ]

  iap_ipv6_ranges = [
    "2600:2d00:1:7::/64"
  ]

  gateway_image_tag = var.gateway_image_tag != null ? var.gateway_image_tag : var.image_tag
  relay_image_tag   = var.relay_image_tag != null ? var.relay_image_tag : var.image_tag
  portal_image_tag  = var.portal_image_tag != null ? var.portal_image_tag : var.image_tag
}

terraform {
  cloud {
    organization = "firezone"
    hostname     = "app.terraform.io"

    workspaces {
      name = "production"
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

  id                 = "firezone-prod"
  name               = "Production Environment"
  organization_id    = "335836213177"
  billing_account_id = "0199BA-489CDD-F385C8"

  auto_create_network = false
}

# Enable audit logs for the production project
resource "google_project_iam_audit_config" "audit" {
  project = module.google-cloud-project.project.project_id

  service = "allServices"

  audit_log_config {
    log_type = "ADMIN_READ"
  }

  audit_log_config {
    log_type = "DATA_READ"

    exempted_members = concat(
      [
        module.web.service_account.member,
        module.api.service_account.member,
        module.metabase.service_account.member,
      ],
      module.gateways[*].service_account.member,
      module.relays[*].service_account.member
    )
  }

  audit_log_config {
    log_type = "DATA_WRITE"

    exempted_members = concat(
      [
        module.web.service_account.member,
        module.api.service_account.member,
        module.metabase.service_account.member,
      ],
      module.gateways[*].service_account.member,
      module.relays[*].service_account.member
    )
  }
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

  writers = [
    # This is GitHub Actions service account configured manually
    # in the project github-iam-387915
    "serviceAccount:github-actions@github-iam-387915.iam.gserviceaccount.com"
  ]
}

# Bucket where CI stores binary artifacts (eg. gateway or client)
resource "google_storage_bucket" "firezone-binary-artifacts" {
  project = module.google-cloud-project.project.project_id
  name    = "${module.google-cloud-project.project.project_id}-artifacts"

  location = "US"

  lifecycle_rule {
    condition {
      age = 365
    }

    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 1
    }

    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  public_access_prevention    = "inherited"
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "public-firezone-binary-artifacts" {
  bucket = google_storage_bucket.firezone-binary-artifacts.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Create a VPCs
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
  dnssec_enabled = true
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

  database_highly_available = true
  database_backups_enabled  = true

  database_read_replica_locations = [
    {
      ipv4_enabled = true
      region       = local.region
      network      = module.google-cloud-vpc.id
    }
  ]

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

resource "google_compute_firewall" "ssh-ipv4" {
  project = module.google-cloud-project.project.project_id

  name    = "iap-ssh-ipv4"
  network = module.google-cloud-vpc.self_link

  allow {
    protocol = "tcp"
    ports    = [22]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }

  # Only allows connections using IAP
  source_ranges = local.iap_ipv4_ranges
  target_tags = concat(
    module.web.target_tags,
    module.api.target_tags,
    module.domain.target_tags,
    module.relays[0].target_tags
  )
}

resource "google_compute_firewall" "ssh-ipv6" {
  project = module.google-cloud-project.project.project_id

  name    = "iap-ssh-ipv6"
  network = module.google-cloud-vpc.self_link

  allow {
    protocol = "tcp"
    ports    = [22]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }

  source_ranges = local.iap_ipv6_ranges
  target_tags = concat(
    module.web.target_tags,
    module.api.target_tags,
    module.domain.target_tags,
    module.relays[0].target_tags
  )
}

module "ops" {
  source = "../../modules/google-cloud/ops"

  project_id = module.google-cloud-project.project.project_id

  slack_alerts_auth_token = var.slack_alerts_auth_token
  slack_alerts_channel    = var.slack_alerts_channel

  pagerduty_auth_token = var.pagerduty_auth_token

  # Feel free to add your Mobile App (due to SOC requirements, only can be used from work devices)
  # or SMS notification  (recommended for personal devices) channels
  additional_notification_channels = [
    # Brian
    ## Mobile App
    # "projects/firezone-prod/notificationChannels/16177228986287373178",
    # Jamil
    ## Mobile App
    # "projects/firezone-prod/notificationChannels/1608881766413151733"
  ]

  api_host = module.api.host
  web_host = module.web.host
}
