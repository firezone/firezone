locals {
  project_owners = [
    "a@firezone.dev",
    "gabriel@firezone.dev",
    "jamil@firezone.dev"
  ]

  region            = "us-east1"
  availability_zone = "us-east1-d"

  tld = "firez.one"
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
  source = "../../modules/google-cloud-project"

  id                 = "firezone-staging"
  name               = "Staging Environment"
  organization_id    = "335836213177"
  billing_account_id = "01DFC9-3D6951-579BE1"
}

# Grant owner access to the project
resource "google_project_iam_binding" "project_owners" {
  project = module.google-cloud-project.project.project_id
  role    = "roles/owner"
  members = formatlist("user:%s", local.project_owners)
}

# Grant GitHub Actions ability to write to the container registry
module "google-artifact-registry" {
  source = "../../modules/google-artifact-registry"

  project_id   = module.google-cloud-project.project.project_id
  project_name = module.google-cloud-project.name

  region = local.region

  writers = [
    # This is GitHub Actions service account configured manually
    # in the project github-iam-387915
    "serviceAccount:github-actions@github-iam-387915.iam.gserviceaccount.com"
  ]
}

# Create a VPC
module "google-cloud-vpc" {
  source = "../../modules/google-cloud-vpc"

  project_id = module.google-cloud-project.project.project_id
  name       = module.google-cloud-project.project.project_id
}

# Enable Google Cloud Storage for the project
module "google-cloud-storage" {
  source = "../../modules/google-cloud-storage"

  project_id = module.google-cloud-project.project.project_id
}

# Create DNS managed zone
module "google-cloud-dns" {
  source = "../../modules/google-cloud-dns"

  project_id = module.google-cloud-project.project.project_id

  tld            = "app.${local.tld}."
  dnssec_enabled = false
}

# Create the Cloud SQL database
module "google-cloud-sql" {
  source     = "../../modules/google-cloud-sql"
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

    # Sets minimum treshold on dead tuples to prevent autovaccum running too often on small tables
    # where 5% is less than 50 records
    "autovacuum_vacuum_threshold" = "50"

    # Trigger autovaccum for every 5% of the table changed
    "autovacuum_vacuum_scale_factor"  = "0.05"
    "autovacuum_analyze_scale_factor" = "0.05"

    # Give autovacuum 4x the cost limit to prevent it from never finishing
    # on big tables
    "autovacuum_vacuum_cost_limit" = "800"

    # Give hash joins a bit more memory to work with
    "hash_mem_multiplier" = "3"

    # This is standard value for work_mem
    "work_mem" = "4096"
  }
}

# Generate secrets
resource "random_string" "erlang_cluster_cookie" {
  length  = 64
  special = false
}

resource "random_string" "auth_token_key_base" {
  length  = 64
  special = false
}

resource "random_string" "auth_token_salt" {
  length  = 32
  special = false
}

resource "random_string" "relays_auth_token_key_base" {
  length  = 64
  special = false
}

resource "random_string" "relays_auth_token_salt" {
  length  = 32
  special = false
}

resource "random_string" "gateways_auth_token_key_base" {
  length  = 64
  special = false
}

resource "random_string" "gateways_auth_token_salt" {
  length  = 32
  special = false
}

resource "random_string" "secret_key_base" {
  length  = 64
  special = false
}

resource "random_string" "live_view_signing_salt" {
  length  = 32
  special = false
}

resource "random_string" "cookie_signing_salt" {
  length  = 32
  special = false
}

resource "random_string" "cookie_encryption_salt" {
  length  = 32
  special = false
}

# # Deploy nginx to the compute for HTTPS termination
# # module "nginx" {
# #   source = "../../modules/nginx"
# #   project_id = module.google-cloud-project.project.project_id
# # }

# Create VPC subnet for the application instances,
# we want all apps to be in the same VPC in order for Erlang clustering to work
resource "google_compute_subnetwork" "apps" {
  project = module.google-cloud-project.project.project_id

  name = "app"

  ip_cidr_range = "10.128.0.0/20"
  region        = local.region
  network       = module.google-cloud-vpc.id

  private_ip_google_access = true
}

# Deploy the web app to the GCE
resource "random_string" "web_db_password" {
  length  = 16
  special = false
}

resource "google_sql_user" "web" {
  project = module.google-cloud-project.project.project_id

  instance = module.google-cloud-sql.master_instance_name

  name     = "web"
  password = random_string.web_db_password.result
}

module "web" {
  source     = "../../modules/elixir-app"
  project_id = module.google-cloud-project.project.project_id

  compute_instance_type              = "n1-standard-1"
  compute_instance_region            = local.region
  compute_instance_availability_zone = "${local.region}-d"

  vpc_network    = module.google-cloud-vpc.self_link
  vpc_subnetwork = google_compute_subnetwork.apps.self_link

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "web"
  image_tag  = "andrew_deployment"

  scaling_horizontal_replicas = 2

  observability_log_level = "debug"

  erlang_release_name   = "firezone"
  erlang_cluster_cookie = random_string.erlang_cluster_cookie.result

  application_name    = "web"
  application_version = "andrew_deployment"

  # application_ports = [
  #   {
  #     protocol = "TCP"
  #     port     = 80
  #   },
  #   {
  #     protocol = "TCP"
  #     port     = 443
  #   }
  # ]

  application_environment_variables = [
    # Web Server
    {
      name  = "EXTERNAL_URL"
      value = "https://app.${local.tld}"
    },
    # Database
    {
      name  = "DATABASE_HOST"
      value = module.google-cloud-sql.master_instance_ip_address
    },
    {
      name  = "DATABASE_NAME"
      value = "firezone"
    },
    {
      name  = "DATABASE_USER"
      value = google_sql_user.web.name
    },
    {
      name  = "DATABASE_PASSWORD"
      value = google_sql_user.web.password
    },
    # Secrets
    {
      name  = "SECRET_KEY_BASE"
      value = random_string.secret_key_base.result
    },
    {
      name  = "AUTH_TOKEN_KEY_BASE"
      value = base64encode(random_string.auth_token_key_base.result)
    },
    {
      name  = "AUTH_TOKEN_SALT"
      value = base64encode(random_string.auth_token_salt.result)
    },
    {
      name  = "RELAYS_AUTH_TOKEN_KEY_BASE"
      value = base64encode(random_string.relays_auth_token_key_base.result)
    },
    {
      name  = "RELAYS_AUTH_TOKEN_SALT"
      value = base64encode(random_string.relays_auth_token_salt.result)
    },
    {
      name  = "GATEWAYS_AUTH_TOKEN_KEY_BASE"
      value = base64encode(random_string.gateways_auth_token_key_base.result)
    },
    {
      name  = "GATEWAYS_AUTH_TOKEN_SALT"
      value = base64encode(random_string.gateways_auth_token_salt.result)
    },
    {
      name  = "SECRET_KEY_BASE"
      value = base64encode(random_string.secret_key_base.result)
    },
    {
      name  = "LIVE_VIEW_SIGNING_SALT"
      value = base64encode(random_string.live_view_signing_salt.result)
    },
    {
      name  = "COOKIE_SIGNING_SALT"
      value = base64encode(random_string.cookie_signing_salt.result)
    },
    {
      name  = "COOKIE_ENCRYPTION_SALT"
      value = base64encode(random_string.cookie_encryption_salt.result)
    },
    # Erlang
    {
      name  = "RELEASE_COOKIE"
      value = base64encode(random_string.erlang_cluster_cookie.result)
    },
    # Auth
    {
      name  = "AUTH_PROVIDER_ADAPTERS"
      value = "email,openid_connect,token"
    },
    # Telemetry
    {
      name  = "TELEMETRY_ENABLED"
      value = "false"
    },
    # TODO: Emails
  ]
}

# resource "google_dns_record_set" "application" {
#   project = module.google-cloud-project.project.project_id

#   name = "${var.application_dns_tld}."
#   type = "A"
#   ttl  = 300

#   managed_zone = var.talkinto_app_dns_managed_zone_name

#   rrdatas = [google_compute_address.app-ip.address]
# }

# Enable SSH on staging
resource "google_compute_firewall" "ssh" {
  project = module.google-cloud-project.project.project_id

  name    = "staging-ssh"
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
  target_tags   = ["app-web", "app-api"]
}
