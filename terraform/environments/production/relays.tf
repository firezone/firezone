module "relays" {
  count = var.relay_token != null ? 1 : 0

  source     = "../../modules/google-cloud/apps/relay"
  project_id = module.google-cloud-project.project.project_id

  # TODO: Remember to update the following published documentation when this changes:
  #  - /website/src/app/kb/deploy/gateways/readme.mdx
  #  - /website/src/app/kb/architecture/tech-stack/readme.mdx
  instances = {
    "africa-south1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["africa-south1-a"]
    }
    "asia-east1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["asia-east1-a"]
    }
    "asia-east2" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["asia-east2-a"]
    }
    "asia-northeast1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["asia-northeast1-a"]
    }
    "asia-northeast2" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["asia-northeast2-a"]
    }
    "asia-northeast3" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["asia-northeast3-a"]
    }
    "asia-south1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["asia-south1-a"]
    }
    "asia-south2" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["asia-south2-a"]
    }
    "asia-southeast1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["asia-southeast1-a"]
    }
    "asia-southeast2" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["asia-southeast2-a"]
    }
    "australia-southeast1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["australia-southeast1-a"]
    }
    "australia-southeast2" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["australia-southeast2-a"]
    }
    "europe-central2" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-central2-a"]
    }
    "europe-north1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-north1-a"]
    }
    "europe-southwest1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-southwest1-a"]
    }
    "europe-west1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-west1-b"]
    }
    "europe-west2" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-west2-a"]
    }
    "europe-west3" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-west3-a"]
    }
    "europe-west4" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-west4-a"]
    }
    "europe-west6" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-west6-a"]
    }
    "europe-west8" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-west8-a"]
    }
    "europe-west9" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-west9-a"]
    }
    "europe-west10" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-west10-a"]
    }
    "europe-west12" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["europe-west12-a"]
    }
    "me-central1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["me-central1-a"]
    }
    # Fails with:
    # Access to the region is unavailable. Please contact our sales team at https://cloud.google.com/contact for further assistance."
    # "me-central2" = {
    #       #   type       = "e2-micro"
    #   replicas   = 1
    #   zones      = ["me-central2-a"]
    # }
    "me-west1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["me-west1-a"]
    }
    "northamerica-northeast1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["northamerica-northeast1-a"]
    }
    "northamerica-northeast2" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["northamerica-northeast2-a"]
    }
    "northamerica-south1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["northamerica-south1-a"]
    }
    "southamerica-east1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["southamerica-east1-a"]
    }
    "southamerica-west1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["southamerica-west1-a"]
    }
    "us-central1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["us-central1-a"]
    }
    "us-east1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["us-east1-b"]
    }
    "us-east4" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["us-east4-a"]
    }
    "us-east5" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["us-east5-a"]
    }
    "us-south1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["us-south1-a"]
    }
    "us-west1" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["us-west1-a"]
    }
    "us-west2" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["us-west2-a"]
    }
    "us-west3" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["us-west3-a"]
    }
    "us-west4" = {
      type     = "e2-micro"
      replicas = 1
      zones    = ["us-west4-a"]
    }
  }

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "relay"
  image_tag  = local.relay_image_tag

  observability_log_level = "info,hyper=off,h2=warn,tower=warn"

  application_name    = "relay"
  application_version = replace(local.relay_image_tag, ".", "-")
  application_environment_variables = [
    {
      name  = "FIREZONE_TELEMETRY"
      value = "true"
    }
  ]

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

# Allow SSH access using IAP for relays
resource "google_compute_firewall" "relays-ssh-ipv4" {
  count = length(module.relays) > 0 ? 1 : 0

  project = module.google-cloud-project.project.project_id

  name    = "relays-ssh-ipv4"
  network = module.relays[0].network

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

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }

  # Only allows connections using IAP
  source_ranges = local.iap_ipv4_ranges
  target_tags   = module.relays[0].target_tags
}

# Trigger an alert when there is at least one region without a healthy relay
resource "google_monitoring_alert_policy" "connected_relays_count" {
  project = module.google-cloud-project.project.project_id

  display_name = "Relays are down"
  combiner     = "OR"

  notification_channels = module.ops.notification_channels

  conditions {
    display_name = "Relay Instances"

    condition_threshold {
      filter     = "resource.type = \"gce_instance\" AND metric.type = \"custom.googleapis.com/elixir/domain/relays/online_relays_count/last_value\""
      comparison = "COMPARISON_LT"

      # at least one relay per region must be always online
      threshold_value = length(module.relays[0].instances)
      duration        = "0s"

      trigger {
        count = 1
      }

      aggregations {
        alignment_period     = "60s"
        cross_series_reducer = "REDUCE_MAX"
        per_series_aligner   = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "172800s"
  }
}
