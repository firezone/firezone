# Enable Cloud SQL for the Google Cloud project

resource "google_project_service" "sqladmin" {
  project = var.project_id
  service = "sqladmin.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "sql-component" {
  project = var.project_id
  service = "sql-component.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "servicenetworking" {
  project = var.project_id
  service = "servicenetworking.googleapis.com"

  disable_on_destroy = false
}

# Create a reserved for Google Cloud SQL address range and connect it to VPC network
resource "google_compute_global_address" "private_ip_pool" {
  project = var.project_id
  network = var.network

  name          = "google-cloud-sql"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
}

resource "google_service_networking_connection" "connection" {
  network = var.network

  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_pool.name]

  depends_on = [
    google_project_service.servicenetworking,
  ]
}

# Create the main Cloud SQL instance
resource "google_sql_database_instance" "master" {
  project = var.project_id

  name             = var.database_name
  database_version = var.database_version
  region           = var.compute_region

  settings {
    tier = "db-custom-${var.compute_instance_cpu_count}-${var.compute_instance_memory_size}"

    disk_type       = "PD_SSD"
    disk_autoresize = true

    activation_policy = "ALWAYS"
    availability_type = var.database_highly_available ? "REGIONAL" : "ZONAL"

    deletion_protection_enabled = strcontains(var.database_name, "-prod") ? true : false

    location_preference {
      zone = var.compute_availability_zone
    }

    backup_configuration {
      # Backups must be enabled if read replicas are enabled
      enabled    = length(var.database_read_replica_locations) > 0 ? true : var.database_backups_enabled
      start_time = "10:00"

      # PITR backups must be enabled if read replicas are enabled
      point_in_time_recovery_enabled = length(var.database_read_replica_locations) > 0 ? true : var.database_backups_enabled

      backup_retention_settings {
        retained_backups = 30
      }
    }

    ip_configuration {
      ipv4_enabled    = true
      private_network = var.network
    }

    maintenance_window {
      day          = 7
      hour         = 8
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = false

      query_plans_per_minute = 20
      query_string_length    = 4500
    }

    password_validation_policy {
      enable_password_policy = true

      complexity = "COMPLEXITY_DEFAULT"

      min_length                  = 16
      disallow_username_substring = true
    }

    dynamic "database_flags" {
      for_each = var.database_flags

      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }

    database_flags {
      name  = "maintenance_work_mem"
      value = floor(var.compute_instance_memory_size * 1024 / 100 * 5)
    }

    database_flags {
      name  = "cloudsql.iam_authentication"
      value = "on"
    }

    database_flags {
      name  = "cloudsql.enable_pgaudit"
      value = "on"
    }

    database_flags {
      name  = "cloudsql.logical_decoding"
      value = "on"
    }

    database_flags {
      name  = "pgaudit.log"
      value = "all"
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = []
  }

  depends_on = [
    google_project_service.sqladmin,
    google_project_service.sql-component,
    google_service_networking_connection.connection,
  ]
}

# Create followers for the main Cloud SQL instance
resource "google_sql_database_instance" "read-replica" {
  for_each = tomap({
    for location in var.database_read_replica_locations : location.region => location
  })

  project = var.project_id

  name             = "${var.database_name}-read-replica-${each.key}"
  database_version = var.database_version
  region           = each.value.region

  master_instance_name = var.database_name

  replica_configuration {
    connect_retry_interval = "30"
  }

  settings {
    # We must use the same tier as the master instance,
    # otherwise it might be lagging behind during the replication and won't be usable
    tier = "db-custom-${var.compute_instance_cpu_count}-${var.compute_instance_memory_size}"

    disk_type       = "PD_SSD"
    disk_autoresize = true

    activation_policy = "ALWAYS"
    availability_type = "ZONAL"

    location_preference {
      zone = var.compute_availability_zone
    }

    ip_configuration {
      ipv4_enabled    = each.value.ipv4_enabled
      private_network = each.value.network
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
      record_client_address   = false

      query_plans_per_minute = 20
      query_string_length    = 4500
    }

    dynamic "database_flags" {
      for_each = var.database_flags

      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = []
  }

  depends_on = [google_sql_database_instance.master]
}
