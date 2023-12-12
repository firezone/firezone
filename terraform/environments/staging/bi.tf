# Deploy our Metabase instance

locals {
  metabase_region = local.region
  metabase_zone   = local.availability_zone
}

resource "random_password" "metabase_db_password" {
  length = 16

  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
  min_special = 1
}

resource "google_sql_user" "metabase" {
  project = module.google-cloud-project.project.project_id

  instance = module.google-cloud-sql.master_instance_name

  name     = "metabase"
  password = random_password.metabase_db_password.result
}

resource "google_sql_database" "metabase" {
  project = module.google-cloud-project.project.project_id

  name     = "metabase"
  instance = module.google-cloud-sql.master_instance_name
}

resource "postgresql_grant" "grant_select_on_all_tables_schema_to_metabase" {
  database = google_sql_database.firezone.name

  privileges  = ["SELECT"]
  objects     = [] # ALL
  object_type = "table"
  schema      = "public"
  role        = google_sql_user.metabase.name

  depends_on = [
    google_sql_user.metabase
  ]
}

resource "postgresql_grant" "grant_execute_on_all_functions_schema_to_metabase" {
  database = google_sql_database.firezone.name

  privileges  = ["EXECUTE"]
  objects     = [] # ALL
  object_type = "function"
  schema      = "public"
  role        = google_sql_user.metabase.name

  depends_on = [
    google_sql_user.metabase
  ]
}

module "metabase" {
  source     = "../../modules/metabase-app"
  project_id = module.google-cloud-project.project.project_id

  compute_network    = module.google-cloud-vpc.id
  compute_subnetwork = google_compute_subnetwork.apps.self_link

  compute_instance_type              = "n1-standard-1"
  compute_region                     = local.metabase_region
  compute_instance_availability_zone = local.metabase_zone

  image_repo = "metabase"
  image      = "metabase"
  image_tag  = var.metabase_image_tag

  application_name    = "metabase"
  application_version = replace(replace(var.metabase_image_tag, ".", "-"), "v", "")

  application_environment_variables = [
    {
      name  = "MB_DB_TYPE"
      value = "postgres"
    },
    {
      name  = "MB_DB_TYPE"
      value = "postgres"
    },
    {
      name  = "MB_DB_DBNAME"
      value = google_sql_database.metabase.name
    },
    {
      name  = "MB_DB_PORT"
      value = "5432"
    },
    {
      name  = "MB_DB_USER"
      value = google_sql_user.metabase.name
    },
    {
      name  = "MB_DB_PASS"
      value = random_password.metabase_db_password.result
    },
    {
      name  = "MB_DB_HOST"
      value = module.google-cloud-sql.bi_instance_ip_address
    },
    {
      name  = "MB_SITE_NAME"
      value = module.google-cloud-project.project.project_id
    },
    {
      name  = "MB_ANON_TRACKING_ENABLED"
      value = "false"
    },
    # {
    #   name = "MB_JETTY_PORT"
    #   value = "80"
    # }
  ]

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
resource "google_compute_firewall" "egress-ipv4" {
  project = module.google-cloud-project.project.project_id

  name      = "metabase-egress-ipv4"
  network   = module.google-cloud-vpc.id
  direction = "EGRESS"

  target_tags        = module.metabase.target_tags
  destination_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "udp"
  }
}

resource "google_compute_firewall" "egress-ipv6" {
  project = module.google-cloud-project.project.project_id

  name      = "metabase-egress-ipv6"
  network   = module.google-cloud-vpc.id
  direction = "EGRESS"

  target_tags        = module.metabase.target_tags
  destination_ranges = ["::/0"]

  allow {
    protocol = "udp"
  }
}

resource "google_compute_firewall" "metabase-ssh-ipv4" {
  project = module.google-cloud-project.project.project_id

  name    = "metabase-ssh-ipv4"
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
  target_tags   = module.metabase.target_tags
}
