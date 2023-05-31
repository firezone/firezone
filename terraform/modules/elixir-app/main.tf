locals {
  application_name    = var.application_name != null ? var.application_name : var.image
  application_version = var.application_version != null ? var.application_version : var.image_tag

  application_labels = merge({
    managed_by  = "terraform"
    application = local.application_name
    version     = local.application_version
  }, var.application_labels)

  application_environment_variables = concat([
    {
      name  = "RELEASE_HOST_DISCOVERY_METHOD"
      value = "gce_metadata"
    }
  ], var.application_environment_variables)

  google_load_balancer_ip_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
  ]
}

# Fetch most recent COS image
data "google_compute_image" "coreos" {
  family  = "cos-105-lts"
  project = "cos-cloud"
}

# # Reserve static IP address for the application instances
# resource "google_compute_address" "app-ip" {
#   count = var.scaling_horizontal_replicas

#   project = var.project_id

#   name   = "app-ip"
#   region = var.region
# }

# Create IAM role for the application instances
resource "google_service_account" "application" {
  project = var.project_id

  account_id   = "app-${local.application_name}"
  display_name = "${local.application_name} app"
  description  = "Service account for ${local.application_name} application instances."
}

# Allow application service account to pull images from the container registry
resource "google_project_iam_binding" "application" {
  project = var.project_id

  role = "roles/artifactregistry.reader"

  members = ["serviceAccount:${google_service_account.application.email}"]
}

# Deploy the app
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
  }, local.application_labels)

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
    provisioning_model  = "STANDARD"
  }

  disk {
    source_image = data.google_compute_image.coreos.self_link
    auto_delete  = true
    boot         = true
  }

  network_interface {
    subnetwork = var.vpc_subnetwork
  }

  service_account {
    email = google_service_account.application.email

    # Those are copying gke-default scopes
    scopes = [
      "storage-ro",
      "logging-write",
      "monitoring",
      "service-management",
      "service-control",
      "trace",
    ]
  }

  metadata = merge({
    gce-container-declaration = yamlencode({
      spec = {
        containers = [{
          name  = local.application_name != null ? local.application_name : var.image
          image = "${var.container_registry}/${var.image_repo}/${var.image}:${var.image_tag}"
          env   = local.application_environment_variables
          stdin = true
        }]

        volumes = []

        restartPolicy = "Always"
      }
    })

    # user-data = file("${path.module}/cloudinit.yaml")

    # Enable FluentBit agent for logging, which will be default one from COS 109
    google-logging-enabled       = "true"
    google-logging-use-fluentbit = "true"

    # Report health-related metrics to Cloud Monitoring
    google-monitoring-enabled = "true"
  })

  depends_on = [
    google_project_service.compute,
    google_project_service.pubsub,
    google_project_service.bigquery,
    google_project_service.container,
    google_project_service.stackdriver,
    google_project_service.logging,
    google_project_service.monitoring,
    google_project_service.clouddebugger,
    google_project_service.cloudprofiler,
    google_project_service.cloudtrace,
    google_project_service.servicenetworking,
  ]

  lifecycle {
    create_before_destroy = true
  }
}


resource "google_compute_health_check" "application" {
  project = var.project_id

  name = "${local.application_name}-mig-health"

  timeout_sec        = 30
  check_interval_sec = 60

  dynamic "tcp_health_check" {
    for_each = var.application_ports

    content {
      port = tcp_health_check.value.port
    }
  }
}

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
    instance_template = google_compute_instance_template.application.self_link
  }

  dynamic "named_port" {
    for_each = var.application_ports

    content {
      name = "${lower(named_port.value.protocol)}-${named_port.value.port}"
      port = named_port.value.port
    }
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.application.self_link
    initial_delay_sec = 60
  }

  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_unavailable_fixed = 1
  }

  depends_on = [
    google_compute_instance_template.application
  ]
}

module "google-http-lb" {
  source  = "GoogleCloudPlatform/lb-http/google"
  version = "~> 9.0"

  project = var.project_id

  name        = "${google_compute_region_instance_group_manager.application.name}-lb"
  target_tags = ["app-${local.application_name}"]

  firewall_networks = [
    var.vpc_network
  ]

  ssl = true

  managed_ssl_certificate_domains = [
    var.application_dns_tld
  ]

  backends = {
    default = {
      description = null
      port        = 80
      protocol    = "HTTP"
      # TODO: use port_name instead of port
      port_name               = "tcp-80"
      timeout_sec             = 10
      enable_cdn              = false
      custom_request_headers  = null
      custom_response_headers = null
      compression_mode        = null

      security_policy      = null
      edge_security_policy = null

      connection_draining_timeout_sec = null
      session_affinity                = null
      affinity_cookie_ttl_sec         = null

      health_check = {
        check_interval_sec  = null
        timeout_sec         = null
        healthy_threshold   = null
        unhealthy_threshold = null
        request_path        = "/"
        port                = 80
        host                = null
        logging             = null
      }

      log_config = {
        enable      = false
        sample_rate = null
      }

      groups = [
        {
          group                        = google_compute_region_instance_group_manager.application.instance_group
          balancing_mode               = null
          capacity_scaler              = null
          description                  = null
          max_connections              = null
          max_connections_per_instance = null
          max_connections_per_endpoint = null
          max_rate                     = null
          max_rate_per_instance        = null
          max_rate_per_endpoint        = null
          max_utilization              = null
        }
      ]

      iap_config = {
        enable               = false
        oauth2_client_id     = ""
        oauth2_client_secret = ""
      }
    }
  }

  labels = local.application_labels
}

# Open HTTP(S) ports for the application instances
resource "google_compute_firewall" "http" {
  project = var.project_id

  name    = "${local.application_name}-firewall-lb-to-instances"
  network = var.vpc_network

  allow {
    protocol = "tcp"
    ports    = [80, 443]
  }

  allow {
    protocol = "udp"
    ports    = [80, 443]
  }

  source_ranges = local.google_load_balancer_ip_ranges
  target_tags   = ["app-${local.application_name}"]
}

resource "google_dns_record_set" "application-ipv4" {
  project = var.project_id

  name = "${var.application_dns_tld}."
  type = "A"
  ttl  = 300

  managed_zone = var.dns_managed_zone_name

  rrdatas = [
    module.google-http-lb.external_ip
  ]
}

resource "google_dns_record_set" "application-ipv6" {
  count = module.google-http-lb.ipv6_enabled == true ? 1 : 0

  project = var.project_id

  name = "${var.application_dns_tld}."
  type = "AAAA"
  ttl  = 300

  managed_zone = var.dns_managed_zone_name

  rrdatas = [
    module.google-http-lb.external_ipv6_address
  ]
}
