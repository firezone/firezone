locals {
  # The version of the Erlang cluster state,
  # change this to prevent new nodes from joining the cluster of the old ones,
  # ie. when some internal messages introduced a breaking change.
  cluster_version   = "1_0"
  api_node_count    = 4
  domain_node_count = 4
  web_node_count    = 4
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

  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    metadata             = "INCLUDE_ALL_METADATA"
  }

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

  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    metadata             = "INCLUDE_ALL_METADATA"
  }

  private_ip_google_access = true
}

# Create SQL user and database
resource "random_password" "web_db_password" {
  length = 16

  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1

  lifecycle {
    ignore_changes = [min_lower, min_upper, min_numeric, min_special]
  }
}

resource "google_sql_user" "web" { # TODO: Rename to 'firezone' to match prod
  project = module.google-cloud-project.project.project_id

  instance = module.google-cloud-sql.master_instance_name

  name     = "web"
  password = random_password.web_db_password.result
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
  username  = google_sql_user.web.name
  password  = random_password.web_db_password.result
  superuser = false
  sslmode   = "disable"

  # Reduce parallelism to avoid "Error: could not execute revoke query: pq: tuple concurrently updated" error
  max_connections = 1
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
    postgresql_grant.grant_select_on_all_tables_schema_to_iam_users, # Permissions cannot be concurrently updated for a role
    google_sql_user.iam_users
  ]
}

locals {
  cluster = {
    name   = "firezone"
    cookie = base64encode(random_password.erlang_cluster_cookie.result)
  }

  shared_application_environment_variables = [
    # Apps
    {
      name  = "WEB_EXTERNAL_URL"
      value = "https://app.${local.tld}"
    },
    {
      name  = "API_EXTERNAL_URL"
      value = "https://api.${local.tld}"
    },
    {
      name  = "PHOENIX_HTTP_WEB_PORT"
      value = "8080"
    },
    {
      name  = "PHOENIX_HTTP_API_PORT"
      value = "8080"
    },
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
      value = google_sql_user.web.name
    },
    {
      name  = "DATABASE_PASSWORD"
      value = google_sql_user.web.password
    },
    # Secrets
    {
      name  = "TOKENS_KEY_BASE"
      value = base64encode(random_password.tokens_key_base.result)
    },
    {
      name  = "TOKENS_SALT"
      value = base64encode(random_password.tokens_salt.result)
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
        cluster_version       = local.cluster_version
        node_name_label       = "application"
        polling_interval_ms   = 10000
        api_node_count        = local.api_node_count
        domain_node_count     = local.domain_node_count
        web_node_count        = local.web_node_count
      })
    },
    {
      name  = "RELEASE_COOKIE"
      value = local.cluster.cookie
    },
    # Auth
    {
      name  = "AUTH_PROVIDER_ADAPTERS"
      value = "email,openid_connect,google_workspace,token,microsoft_entra,okta,jumpcloud"
    },
    # Registry from which Docker install scripts pull from
    {
      name  = "DOCKER_REGISTRY"
      value = "${module.google-artifact-registry.url}/${module.google-artifact-registry.repo}"
    },
    # Directory Sync
    {
      name  = "WORKOS_API_KEY"
      value = var.workos_api_key
    },
    {
      name  = "WORKOS_CLIENT_ID"
      value = var.workos_client_id
    },
    {
      name  = "WORKOS_BASE_URL"
      value = var.workos_base_url
    },
    # Billing system
    {
      name  = "BILLING_ENABLED"
      value = "true"
    },
    {
      name  = "STRIPE_SECRET_KEY"
      value = var.stripe_secret_key
    },
    {
      name  = "STRIPE_WEBHOOK_SIGNING_SECRET"
      value = var.stripe_webhook_signing_secret
    },
    {
      name  = "STRIPE_DEFAULT_PRICE_ID"
      value = var.stripe_default_price_id
    },
    # Analytics
    {
      name = "MIXPANEL_TOKEN"
      # Note: this token is public
      value = "313bdddc66b911f4afeb2c3242a78113"
    },
    {
      name  = "HUBSPOT_WORKSPACE_ID"
      value = "23723443" # from prod, but this is ok
    },
    # Emails
    {
      name  = "OUTBOUND_EMAIL_ADAPTER"
      value = "Elixir.Swoosh.Adapters.Mailgun"
    },
    {
      name  = "OUTBOUND_EMAIL_FROM"
      value = "notifications@firez.one"
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
      name  = "FEATURE_FLOW_ACTIVITIES_ENABLED"
      value = true
    },
    {
      name  = "FEATURE_SELF_HOSTED_RELAYS_ENABLED"
      value = true
    },
    {
      name  = "FEATURE_POLICY_CONDITIONS_ENABLED"
      value = true
    },
    {
      name  = "FEATURE_MULTI_SITE_RESOURCES_ENABLED"
      value = true
    },
    {
      name  = "FEATURE_SIGN_UP_ENABLED"
      value = true
    },
    # Only allow sign up with whitelisted domains
    {
      name  = "SIGN_UP_WHITELISTED_DOMAINS"
      value = "firezone.dev,firez.one"
    },
    {
      name  = "FEATURE_REST_API_ENABLED"
      value = true
    },
    {
      name  = "FEATURE_INTERNET_RESOURCE_ENABLED"
      value = true
    },
    {
      name  = "FEATURE_TEMP_ACCOUNTS"
      value = true
    }
  ]
}

module "domain" {
  source     = "../../modules/google-cloud/apps/elixir"
  project_id = module.google-cloud-project.project.project_id

  compute_instance_type               = "e2-micro"
  compute_instance_region             = local.region
  compute_instance_availability_zones = ["${local.region}-d"]
  compute_boot_disk_type              = "pd-balanced"

  dns_managed_zone_name = module.google-cloud-dns.zone_name

  vpc_network    = module.google-cloud-vpc.self_link
  vpc_subnetwork = google_compute_subnetwork.apps.self_link

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "domain"
  image_tag  = var.image_tag

  scaling_horizontal_replicas = local.domain_node_count

  observability_log_level = "debug"

  erlang_release_name   = "firezone"
  erlang_cluster_cookie = random_password.erlang_cluster_cookie.result

  application_name    = "domain"
  application_version = replace(var.image_tag, ".", "-")

  application_ports = [
    {
      name     = "http"
      protocol = "TCP"
      port     = 4000

      health_check = {
        initial_delay_sec   = 45
        check_interval_sec  = 5
        timeout_sec         = 5
        healthy_threshold   = 1
        unhealthy_threshold = 10

        http_health_check = {
          request_path = "/healthz"
        }
      }
    }
  ]

  application_environment_variables = concat([
    # Background Jobs
    {
      name  = "BACKGROUND_JOBS_ENABLED"
      value = "true"
    },
  ], local.shared_application_environment_variables)

  application_labels = {
    "cluster_name"    = local.cluster.name
    "cluster_version" = local.cluster_version
  }

  otel_config = file("./otel/domain.yaml")

  compute_swap_size_gb = 1
}

module "web" {
  source     = "../../modules/google-cloud/apps/elixir"
  project_id = module.google-cloud-project.project.project_id

  compute_instance_type               = "e2-micro"
  compute_instance_region             = local.region
  compute_instance_availability_zones = ["${local.region}-d"]
  compute_boot_disk_type              = "pd-balanced"

  dns_managed_zone_name = module.google-cloud-dns.zone_name

  vpc_network    = module.google-cloud-vpc.self_link
  vpc_subnetwork = google_compute_subnetwork.apps.self_link

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "web"
  image_tag  = var.image_tag

  scaling_horizontal_replicas = local.web_node_count

  observability_log_level = "debug"

  erlang_release_name   = "firezone"
  erlang_cluster_cookie = random_password.erlang_cluster_cookie.result

  application_name    = "web"
  application_version = replace(var.image_tag, ".", "-")

  application_dns_tld = "app.${local.tld}"

  application_cdn_enabled = true

  application_ports = [
    {
      name     = "http"
      protocol = "TCP"
      port     = 8080

      health_check = {
        initial_delay_sec   = 45
        check_interval_sec  = 5
        timeout_sec         = 5
        healthy_threshold   = 1
        unhealthy_threshold = 10

        http_health_check = {
          request_path = "/healthz"
        }
      }
    }
  ]

  application_environment_variables = concat([
    # Web Server
    {
      name  = "API_URL_OVERRIDE"
      value = "wss://api.${local.tld}"
    },
    {
      name  = "BACKGROUND_JOBS_ENABLED"
      value = "false"
    },
  ], local.shared_application_environment_variables)

  application_labels = {
    "cluster_name"    = local.cluster.name
    "cluster_version" = local.cluster_version
  }

  otel_config = file("./otel/web.yaml")

  compute_swap_size_gb = 1
}

module "api" {
  source     = "../../modules/google-cloud/apps/elixir"
  project_id = module.google-cloud-project.project.project_id

  compute_instance_type               = "e2-micro"
  compute_instance_region             = local.region
  compute_instance_availability_zones = ["${local.region}-d"]
  compute_boot_disk_type              = "pd-balanced"

  dns_managed_zone_name = module.google-cloud-dns.zone_name

  vpc_network    = module.google-cloud-vpc.self_link
  vpc_subnetwork = google_compute_subnetwork.apps.self_link

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "api"
  image_tag  = var.image_tag

  scaling_horizontal_replicas = local.api_node_count

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
        initial_delay_sec   = 45
        check_interval_sec  = 5
        timeout_sec         = 5
        healthy_threshold   = 1
        unhealthy_threshold = 10

        http_health_check = {
          request_path = "/healthz"
        }
      }
    }
  ]

  application_environment_variables = concat([
    # Web Server
    {
      name  = "BACKGROUND_JOBS_ENABLED"
      value = "false"
    },
  ], local.shared_application_environment_variables)

  application_labels = {
    "cluster_name"    = local.cluster.name
    "cluster_version" = local.cluster_version
  }

  application_token_scopes = [
    "https://www.googleapis.com/auth/cloud-platform"
  ]

  otel_config = file("./otel/api.yaml")

  compute_swap_size_gb = 1
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
  target_tags   = concat(module.web.target_tags, module.api.target_tags, module.domain.target_tags)
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
    api    = module.api.service_account.email
    web    = module.web.service_account.email
    domain = module.domain.service_account.email
  }

  project = module.google-cloud-project.project.project_id

  role   = "projects/${module.google-cloud-project.project.project_id}/roles/${google_project_iam_custom_role.erlang-discovery.role_id}"
  member = "serviceAccount:${each.value}"
}
