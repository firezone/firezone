locals {
  project_owners = [
    "a@firezone.dev",
    "bmanifold@firezone.dev",
    "gabriel@firezone.dev",
    "jamil@firezone.dev",
    "thomas@firezone.dev"
  ]

  region            = "us-east1"
  availability_zone = "us-east1-d"

  tld = "firezone.dev"

  iap_ipv4_ranges = [
    "35.235.240.0/20"
  ]
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
  source = "../../modules/google-cloud-project"

  id                 = "firezone-prod"
  name               = "Production Environment"
  organization_id    = "335836213177"
  billing_account_id = "01DFC9-3D6951-579BE1"
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

  nat_region = local.region
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

  tld            = local.tld
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

  database_highly_available = true
  database_backups_enabled  = true

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

# Generate secrets
resource "random_password" "erlang_cluster_cookie" {
  length  = 64
  special = false
}

resource "random_password" "tokens_key_base" {
  length  = 64
  special = false
}

resource "random_password" "tokens_salt" {
  length  = 32
  special = false
}

resource "random_password" "secret_key_base" {
  length  = 64
  special = false
}

resource "random_password" "live_view_signing_salt" {
  length  = 32
  special = false
}

resource "random_password" "cookie_signing_salt" {
  length  = 32
  special = false
}

resource "random_password" "cookie_encryption_salt" {
  length  = 32
  special = false
}

# Create VPC subnet for the application instances,
# we want all apps to be in the same VPC in order for Erlang clustering to work
resource "google_compute_subnetwork" "apps" {
  project = module.google-cloud-project.project.project_id

  name = "app"

  stack_type = "IPV4_IPV6"

  ip_cidr_range = "10.128.0.0/20"
  region        = local.region
  network       = module.google-cloud-vpc.id

  ipv6_access_type = "EXTERNAL"

  private_ip_google_access = true
}

# Create VPN subnet for tooling instances
resource "google_compute_subnetwork" "tools" {
  project = module.google-cloud-project.project.project_id

  name = "tooling"

  stack_type = "IPV4_IPV6"

  ip_cidr_range = "10.129.0.0/20"
  region        = local.region
  network       = module.google-cloud-vpc.id

  ipv6_access_type = "EXTERNAL"

  private_ip_google_access = true
}

# Create SQL user and database
resource "random_password" "firezone_db_password" {
  length = 16

  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1

  lifecycle {
    ignore_changes = [min_lower, min_upper, min_numeric, min_special]
  }
}

resource "google_sql_user" "firezone" {
  project = module.google-cloud-project.project.project_id

  instance = module.google-cloud-sql.master_instance_name

  name     = "firezone"
  password = random_password.firezone_db_password.result
}

resource "google_sql_database" "firezone" {
  project = module.google-cloud-project.project.project_id

  name     = "firezone"
  instance = module.google-cloud-sql.master_instance_name
}

# Create IAM users for the database for all project owners
resource "google_sql_user" "iam_users" {
  for_each = toset(local.project_owners)

  project  = module.google-cloud-project.project.project_id
  instance = module.google-cloud-sql.master_instance_name

  type = "CLOUD_IAM_USER"
  name = each.value
}

# We can't remove passwords complete because for IAM users we still need to execute those GRANT statements
provider "postgresql" {
  scheme    = "gcppostgres"
  host      = "${module.google-cloud-project.project.project_id}:${local.region}:${module.google-cloud-sql.master_instance_name}"
  port      = 5432
  username  = google_sql_user.firezone.name
  password  = random_password.firezone_db_password.result
  superuser = false
  sslmode   = "disable"
}

resource "postgresql_grant" "grant_select_on_all_tables_schema_to_iam_users" {
  for_each = toset(local.project_owners)

  database = google_sql_database.firezone.name

  privileges  = ["SELECT", "INSERT", "UPDATE", "DELETE"]
  objects     = [] # ALL
  object_type = "table"
  schema      = "public"
  role        = each.key

  depends_on = [
    google_sql_user.iam_users
  ]
}

resource "postgresql_grant" "grant_execute_on_all_functions_schema_to_iam_users" {
  for_each = toset(local.project_owners)

  database = google_sql_database.firezone.name

  privileges  = ["EXECUTE"]
  objects     = [] # ALL
  object_type = "function"
  schema      = "public"
  role        = each.key

  depends_on = [
    google_sql_user.iam_users
  ]
}

# Create bucket for client logs
resource "google_storage_bucket" "client-logs" {
  project = module.google-cloud-project.project.project_id
  name    = "${module.google-cloud-project.project.project_id}-client-logs"

  location = "US"

  lifecycle_rule {
    condition {
      age = 3
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

  logging {
    log_bucket        = true
    log_object_prefix = "firezone.dev/clients"
  }

  public_access_prevention    = "enforced"
  uniform_bucket_level_access = true

  lifecycle {
    prevent_destroy = true
    ignore_changes  = []
  }
}

locals {
  cluster = {
    name   = "firezone"
    cookie = base64encode(random_password.erlang_cluster_cookie.result)
  }

  shared_application_environment_variables = [
    # Database
    {
      name  = "DATABASE_HOST"
      value = module.google-cloud-sql.master_instance_ip_address
    },
    {
      name  = "DATABASE_NAME"
      value = google_sql_database.firezone.name
    },
    {
      name  = "DATABASE_USER"
      value = google_sql_user.firezone.name
    },
    {
      name  = "DATABASE_PASSWORD"
      value = google_sql_user.firezone.password
    },
    # Secrets
    {
      name  = "SECRET_KEY_BASE"
      value = random_password.secret_key_base.result
    },
    {
      name  = "TOKENS_KEY_BASE"
      value = base64encode(random_password.tokens_key_base.result)
    },
    {
      name  = "TOKENS_SALT"
      value = base64encode(random_password.tokens_salt.result)
    },
    {
      name  = "GATEWAYS_AUTH_TOKEN_KEY_BASE"
      value = base64encode(random_password.gateways_auth_token_key_base.result)
    },
    {
      name  = "GATEWAYS_AUTH_TOKEN_SALT"
      value = base64encode(random_password.gateways_auth_token_salt.result)
    },
    {
      name  = "SECRET_KEY_BASE"
      value = base64encode(random_password.secret_key_base.result)
    },
    {
      name  = "LIVE_VIEW_SIGNING_SALT"
      value = base64encode(random_password.live_view_signing_salt.result)
    },
    {
      name  = "COOKIE_SIGNING_SALT"
      value = base64encode(random_password.cookie_signing_salt.result)
    },
    {
      name  = "COOKIE_ENCRYPTION_SALT"
      value = base64encode(random_password.cookie_encryption_salt.result)
    },
    # Erlang
    {
      name  = "ERLANG_DISTRIBUTION_PORT"
      value = "9000"
    },
    {
      name  = "CLUSTER_NAME"
      value = local.cluster.name
    },
    {
      name  = "ERLANG_CLUSTER_ADAPTER"
      value = "Elixir.Domain.Cluster.GoogleComputeLabelsStrategy"
    },
    {
      name = "ERLANG_CLUSTER_ADAPTER_CONFIG"
      value = jsonencode({
        project_id            = module.google-cloud-project.project.project_id
        cluster_name          = local.cluster.name
        cluster_name_label    = "cluster_name"
        cluster_version_label = "cluster_version"
        cluster_version       = split(".", var.image_tag)[0]
        node_name_label       = "application"
        polling_interval_ms   = 7000
      })
    },
    {
      name  = "RELEASE_COOKIE"
      value = local.cluster.cookie
    },
    # Auth
    {
      name  = "AUTH_PROVIDER_ADAPTERS"
      value = "email,openid_connect,google_workspace,token"
    },
    # Registry from which Docker install scripts pull from
    {
      name  = "DOCKER_REGISTRY"
      value = "ghcr.io/firezone"
    },
    # Telemetry
    {
      name  = "TELEMETRY_ENABLED"
      value = "false"
    },
    {
      name  = "INSTRUMENTATION_CLIENT_LOGS_ENABLED"
      value = true
    },
    {
      name  = "INSTRUMENTATION_CLIENT_LOGS_BUCKET"
      value = google_storage_bucket.client-logs.name
    },
    # Emails
    {
      name  = "OUTBOUND_EMAIL_ADAPTER"
      value = "Elixir.Swoosh.Adapters.Mailgun"
    },
    {
      name  = "OUTBOUND_EMAIL_FROM"
      value = "notifications@firezone.dev"
    },
    {
      name = "OUTBOUND_EMAIL_ADAPTER_OPTS"
      value = jsonencode({
        api_key = var.mailgun_server_api_token,
        domain  = local.tld
      })
    },
    # Feature Flags
    {
      name  = "FEATURE_SIGN_UP_ENABLED"
      value = false
    }
  ]
}

module "web" {
  source     = "../../modules/elixir-app"
  project_id = module.google-cloud-project.project.project_id

  compute_instance_type               = "n1-standard-1"
  compute_instance_region             = local.region
  compute_instance_availability_zones = ["${local.region}-d"]

  dns_managed_zone_name = module.google-cloud-dns.zone_name

  vpc_network    = module.google-cloud-vpc.self_link
  vpc_subnetwork = google_compute_subnetwork.apps.self_link

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "web"
  image_tag  = var.image_tag

  scaling_horizontal_replicas = 2

  observability_log_level = "debug"

  erlang_release_name   = "firezone"
  erlang_cluster_cookie = random_password.erlang_cluster_cookie.result

  application_name    = "web"
  application_version = replace(var.image_tag, ".", "-")

  application_dns_tld = "app.${local.tld}"

  application_ports = [
    {
      name     = "http"
      protocol = "TCP"
      port     = 8080

      health_check = {
        initial_delay_sec = 60

        check_interval_sec  = 15
        timeout_sec         = 10
        healthy_threshold   = 1
        unhealthy_threshold = 2

        http_health_check = {
          request_path = "/healthz"
        }
      }
    }
  ]

  application_environment_variables = concat([
    # Web Server
    {
      name  = "EXTERNAL_URL"
      value = "https://app.${local.tld}"
    },
    {
      name  = "PHOENIX_HTTP_WEB_PORT"
      value = "8080"
    }
  ], local.shared_application_environment_variables)

  application_labels = {
    "cluster_name"    = local.cluster.name
    "cluster_version" = split(".", var.image_tag)[0]
  }
}

module "api" {
  source     = "../../modules/elixir-app"
  project_id = module.google-cloud-project.project.project_id

  compute_instance_type               = "n1-standard-1"
  compute_instance_region             = local.region
  compute_instance_availability_zones = ["${local.region}-d"]

  dns_managed_zone_name = module.google-cloud-dns.zone_name

  vpc_network    = module.google-cloud-vpc.self_link
  vpc_subnetwork = google_compute_subnetwork.apps.self_link

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "api"
  image_tag  = var.image_tag

  scaling_horizontal_replicas = 2

  observability_log_level = "debug"

  erlang_release_name   = "firezone"
  erlang_cluster_cookie = random_password.erlang_cluster_cookie.result

  application_name    = "api"
  application_version = replace(var.image_tag, ".", "-")

  application_dns_tld = "api.${local.tld}"

  application_ports = [
    {
      name     = "http"
      protocol = "TCP"
      port     = 8080

      health_check = {
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
  ]

  application_environment_variables = concat([
    # Web Server
    {
      name  = "EXTERNAL_URL"
      value = "https://api.${local.tld}"
    },
    {
      name  = "PHOENIX_HTTP_API_PORT"
      value = "8080"
    },
  ], local.shared_application_environment_variables)

  application_labels = {
    "cluster_name"    = local.cluster.name
    "cluster_version" = split(".", var.image_tag)[0]
  }

  application_token_scopes = [
    "https://www.googleapis.com/auth/cloud-platform"
  ]
}

## Allow API nodes to sign URLs for Google Cloud Storage
resource "google_storage_bucket_iam_member" "sign-urls" {
  bucket = google_storage_bucket.client-logs.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${module.api.service_account.email}"
}

resource "google_project_iam_custom_role" "sign-urls" {
  project = module.google-cloud-project.project.project_id

  title = "Sign URLs for Google Cloud Storage"

  role_id = "iam.sign_urls"

  permissions = [
    "iam.serviceAccounts.signBlob"
  ]
}

resource "google_project_iam_member" "sign-urls" {
  project = module.google-cloud-project.project.project_id
  role    = "projects/${module.google-cloud-project.project.project_id}/roles/${google_project_iam_custom_role.sign-urls.role_id}"
  member  = "serviceAccount:${module.api.service_account.email}"
}

# Erlang Cluster
## Allow traffic between Elixir apps for Erlang clustering
resource "google_compute_firewall" "erlang-distribution" {
  project = module.google-cloud-project.project.project_id

  name    = "erlang-distribution"
  network = module.google-cloud-vpc.self_link

  allow {
    protocol = "tcp"
    ports    = [4369, 9000]
  }

  allow {
    protocol = "udp"
    ports    = [4369, 9000]
  }

  source_ranges = [google_compute_subnetwork.apps.ip_cidr_range]
  target_tags   = concat(module.web.target_tags, module.api.target_tags)
}

## Allow service account to list running instances
resource "google_project_iam_custom_role" "erlang-discovery" {
  project = module.google-cloud-project.project.project_id

  title       = "Read list of Compute instances"
  description = "This role is used for Erlang Cluster discovery and allows to list running instances."

  role_id = "compute.list_instances"
  permissions = [
    "compute.instances.list",
    "compute.zones.list"
  ]
}

resource "google_project_iam_member" "application" {
  for_each = {
    api = module.api.service_account.email
    web = module.web.service_account.email
  }

  project = module.google-cloud-project.project.project_id

  role   = "projects/${module.google-cloud-project.project.project_id}/roles/${google_project_iam_custom_role.erlang-discovery.role_id}"
  member = "serviceAccount:${each.value}"
}

# Deploy relays
module "relays" {
  count = var.relay_token != null ? 1 : 0

  source     = "../../modules/relay-app"
  project_id = module.google-cloud-project.project.project_id

  instances = {
    "asia-east1" = {
      type     = "n1-standard-1"
      replicas = 1
      zones    = ["asia-east1-a"]
    }

    "asia-south1" = {
      type     = "n1-standard-1"
      replicas = 1
      zones    = ["asia-south1-a"]
    }

    "australia-southeast1" = {
      type     = "n1-standard-1"
      replicas = 1
      zones    = ["australia-southeast1-a"]
    }

    "me-central1" = {
      type     = "n2-standard-2"
      replicas = 1
      zones    = ["me-central1-a"]
    }

    "europe-west1" = {
      type     = "n1-standard-1"
      replicas = 1
      zones    = ["europe-west1-d"]
    }

    "southamerica-east1" = {
      type     = "n1-standard-1"
      replicas = 1
      zones    = ["southamerica-east1-b"]
    }

    "us-east1" = {
      type     = "n1-standard-1"
      replicas = 1
      zones    = ["us-east1-d"]
    }

    "us-west2" = {
      type     = "n1-standard-1"
      replicas = 1
      zones    = ["us-west2-b"]
    }

    "us-central1" = {
      type     = "n1-standard-1"
      replicas = 1
      zones    = ["us-central1-b"]
    }
  }

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "relay"
  image_tag  = var.image_tag

  observability_log_level = "debug,firezone_relay=trace,hyper=off,h2=warn,tower=warn,wire=trace"

  application_name    = "relay"
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
  token   = var.relay_token
}

resource "google_compute_firewall" "portal-ssh-ipv4" {
  project = module.google-cloud-project.project.project_id

  name    = "portal-ssh-ipv4"
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

  # Only allows connections using IAP
  source_ranges = local.iap_ipv4_ranges
  target_tags   = concat(module.web.target_tags, module.api.target_tags)
}

resource "google_compute_firewall" "relays-ssh-ipv4" {
  count = length(module.relays) > 0 ? 1 : 0

  project = module.google-cloud-project.project.project_id

  name    = "relays-ssh-ipv4"
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

  # Only allows connections using IAP
  source_ranges = local.iap_ipv4_ranges
  target_tags   = module.relays[0].target_tags
}

module "ops" {
  source = "../../modules/google-cloud-ops"

  project_id = module.google-cloud-project.project.project_id

  slack_alerts_auth_token = var.slack_alerts_auth_token
  slack_alerts_channel    = var.slack_alerts_channel

  pagerduty_auth_token = var.pagerduty_auth_token

  api_host = module.api.host
  web_host = module.web.host
}
