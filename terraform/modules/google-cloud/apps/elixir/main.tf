locals {
  application_name    = var.application_name != null ? var.application_name : var.image
  application_version = var.application_version != null ? var.application_version : var.image_tag

  application_labels = merge({
    managed_by = "terraform"

    # Note: this labels are used to fetch a release name for Erlang Cluster
    application = local.application_name
  }, var.application_labels)

  application_environment_variables = concat([
    {
      name  = "RELEASE_HOST_DISCOVERY_METHOD"
      value = "gce_metadata"
    },
    {
      name = "PHOENIX_EXTERNAL_TRUSTED_PROXIES"
      value = jsonencode(concat(
        [
          "35.191.0.0/16",
          "130.211.0.0/22"
        ],
        google_compute_global_address.ipv4[*].address,
        google_compute_global_address.ipv6[*].address
      ))
    },
    {
      name  = "LOG_LEVEL"
      value = var.observability_log_level
    },
    {
      name  = "OTLP_ENDPOINT",
      value = "http://localhost:4318"
    },
    {
      name  = "OTEL_RESOURCE_ATTRIBUTES"
      value = "application.name=${local.application_name}"
    },
    {
      name  = "TELEMETRY_METRICS_REPORTER"
      value = "Elixir.Domain.Telemetry.Reporter.GoogleCloudMetrics"
    },
    {
      name = "TELEMETRY_METRICS_REPORTER_OPTS"
      value = jsonencode({
        project_id = var.project_id
      })
    },
    {
      name  = "LOGGER_FORMATTER"
      value = "Elixir.LoggerJSON.Formatters.GoogleCloud"
    },
    {
      name = "LOGGER_FORMATTER_OPTS"
      value = jsonencode({
        project_id = var.project_id
      })
    },
    {
      name  = "PLATFORM_ADAPTER"
      value = "Elixir.Domain.GoogleCloudPlatform"
    },
    {
      name = "PLATFORM_ADAPTER_CONFIG"
      value = jsonencode({
        project_id            = var.project_id
        service_account_email = google_service_account.application.email
      })
    }
  ], var.application_environment_variables)

  application_ports_by_name = { for port in var.application_ports : port.name => port }
}

# Fetch most recent COS image
data "google_compute_image" "coreos" {
  family  = "cos-113-lts"
  project = "cos-cloud"
}

# Reserve instances for the application
# If you don't reserve them deployment takes much longer and there is no guarantee that instances will be created at all,
# Google Cloud Platform does not guarantee that instances will be available when you need them.
resource "google_compute_reservation" "reservation" {
  # for_each = toset(var.compute_instance_availability_zones)

  project = var.project_id

  # name = "${local.application_name}-${each.key}-${var.compute_instance_type}"
  name = "${local.application_name}-${element(var.compute_instance_availability_zones, length(var.compute_instance_availability_zones) - 1)}-${var.compute_instance_type}"
  # zone = each.key
  zone = element(var.compute_instance_availability_zones, length(var.compute_instance_availability_zones) - 1)

  specific_reservation_required = true

  specific_reservation {
    count = var.scaling_horizontal_replicas
    # count = ceil(var.scaling_horizontal_replicas / length(var.compute_instance_availability_zones))

    instance_properties {
      machine_type = var.compute_instance_type
    }
  }
}

# Deploy app
resource "google_compute_instance_template" "application" {
  project = var.project_id

  name_prefix = "${local.application_name}-"

  description = "This template is used to create ${local.application_name} instances."

  machine_type = var.compute_instance_type
  region       = var.compute_instance_region

  can_ip_forward = false

  tags = ["app-${local.application_name}"]

  labels = merge({
    container-vm = data.google_compute_image.coreos.name

    # This variable can be used by Erlang Cluster not to join nodes of older versions
    version = local.application_version
  }, local.application_labels)


  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  reservation_affinity {
    type = "SPECIFIC_RESERVATION"

    specific_reservation {
      key = "compute.googleapis.com/reservation-name"
      # *Regional* instance group can consume only one reservation, which is zonal by default,
      # so we are always locked to one zone per region until Google Cloud Platform will fix that.
      # values = [for r in google_compute_reservation.reservation : r.name]
      values = [google_compute_reservation.reservation.name]
    }
  }

  disk {
    source_image = data.google_compute_image.coreos.self_link
    auto_delete  = true
    boot         = true
    disk_type    = var.compute_boot_disk_type
  }

  network_interface {
    subnetwork  = var.vpc_subnetwork
    nic_type    = "GVNIC"
    queue_count = var.queue_count
    stack_type  = "IPV4_IPV6"

    ipv6_access_config {
      network_tier = "PREMIUM"
    }
  }

  service_account {
    email = google_service_account.application.email

    scopes = concat([
      # Those are default scopes
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
      # Required to discover the other instances in the Erlang Cluster
      "https://www.googleapis.com/auth/compute.readonly"
    ], var.application_token_scopes)
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = false
    enable_vtpm                 = true
  }

  metadata = {
    gce-container-declaration = yamlencode({
      spec = {
        containers = [{
          name  = local.application_name != null ? local.application_name : var.image
          image = "${var.container_registry}/${var.image_repo}/${var.image}:${var.image_tag}"
          env   = local.application_environment_variables
        }]

        volumes = []

        restartPolicy = "Always"
      }
    })

    user-data = templatefile("${path.module}/templates/cloud-init.yaml", {
      swap_size_gb = var.compute_swap_size_gb
    })

    google-logging-enabled       = "true"
    google-logging-use-fluentbit = "true"

    # Report health-related metrics to Cloud Monitoring
    google-monitoring-enabled = "true"
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.pubsub,
    google_project_service.bigquery,
    google_project_service.container,
    google_project_service.stackdriver,
    google_project_service.logging,
    google_project_service.monitoring,
    google_project_service.cloudprofiler,
    google_project_service.cloudtrace,
    google_project_service.servicenetworking,
    google_project_iam_member.artifacts,
    google_project_iam_member.logs,
    google_project_iam_member.errors,
    google_project_iam_member.metrics,
    google_project_iam_member.service_management,
    google_project_iam_member.cloudtrace,
    google_compute_reservation.reservation,
  ]

  lifecycle {
    create_before_destroy = true
  }
}

# Create health checks for the application ports
resource "google_compute_health_check" "port" {
  for_each = { for port in var.application_ports : port.name => port if try(port.health_check, null) != null }

  project = var.project_id

  name = "${local.application_name}-${each.key}"

  check_interval_sec  = each.value.health_check.check_interval_sec != null ? each.value.health_check.check_interval_sec : 5
  timeout_sec         = each.value.health_check.timeout_sec != null ? each.value.health_check.timeout_sec : 5
  healthy_threshold   = each.value.health_check.healthy_threshold != null ? each.value.health_check.healthy_threshold : 2
  unhealthy_threshold = each.value.health_check.unhealthy_threshold != null ? each.value.health_check.unhealthy_threshold : 2

  log_config {
    enable = false
  }

  dynamic "tcp_health_check" {
    for_each = try(each.value.health_check.tcp_health_check, null)[*]

    content {
      port = each.value.port

      response = lookup(tcp_health_check.value, "response", null)
    }
  }

  dynamic "http_health_check" {
    for_each = try(each.value.health_check.http_health_check, null)[*]

    content {
      port = each.value.port

      host         = lookup(http_health_check.value, "host", null)
      request_path = lookup(http_health_check.value, "request_path", null)
      response     = lookup(http_health_check.value, "response", null)
    }
  }

  dynamic "https_health_check" {
    for_each = try(each.value.health_check.https_health_check, null)[*]

    content {
      port = each.value.port

      host         = lookup(https_health_check.value, "host", null)
      request_path = lookup(https_health_check.value, "request_path", null)
      response     = lookup(http_health_check.value, "response", null)
    }
  }

  depends_on = [
    google_project_service.compute,
    google_project_service.servicenetworking,
  ]
}

# Use template to deploy zonal instance group
resource "google_compute_region_instance_group_manager" "application" {
  project = var.project_id

  name = "${local.application_name}-group"

  base_instance_name        = local.application_name
  region                    = var.compute_instance_region
  distribution_policy_zones = var.compute_instance_availability_zones

  target_size = var.scaling_horizontal_replicas

  wait_for_instances        = true
  wait_for_instances_status = "STABLE"

  version {
    name              = local.application_version
    instance_template = google_compute_instance_template.application.self_link
  }

  dynamic "named_port" {
    for_each = var.application_ports

    content {
      name = named_port.value.name
      port = named_port.value.port
    }
  }

  dynamic "auto_healing_policies" {
    for_each = try([google_compute_health_check.port["http"].self_link], [])

    content {
      initial_delay_sec = local.application_ports_by_name["http"].health_check.initial_delay_sec

      health_check = auto_healing_policies.value
    }
  }

  update_policy {
    type           = "PROACTIVE"
    minimal_action = "REPLACE"

    # With reservations we need to take one instance down before provisioning a new one,
    # otherwise we will get an error that there are no available instances for the targeted
    # reservation.
    max_unavailable_fixed = 1
    max_surge_fixed       = max(max(1, var.scaling_horizontal_replicas - 1), length(var.compute_instance_availability_zones))
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "20m"
  }

  depends_on = [
    google_compute_instance_template.application
  ]
}

# Auto-scale instances with high CPU and Memory usage
resource "google_compute_region_autoscaler" "application" {
  count = var.scaling_max_horizontal_replicas != null ? 1 : 0

  project = var.project_id

  name = "${local.application_name}-autoscaler"

  region = var.compute_instance_region
  target = google_compute_region_instance_group_manager.application.id

  autoscaling_policy {
    max_replicas = var.scaling_max_horizontal_replicas
    min_replicas = var.scaling_horizontal_replicas

    # wait 3 minutes before trying to measure the CPU utilization for new instances
    cooldown_period = 180

    cpu_utilization {
      target = 0.8
    }
  }
}
