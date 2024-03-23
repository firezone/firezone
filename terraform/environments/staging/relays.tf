module "relays" {
  count = var.relay_token != null ? 1 : 0

  source     = "../../modules/google-cloud/apps/relay"
  project_id = module.google-cloud-project.project.project_id

  instances = {
    "australia-southeast1" = {
      cidr_range = "10.131.0.0/24"

      type     = "f1-micro"
      replicas = 1
      zones    = ["australia-southeast1-a"]
    }

    "southamerica-east1" = {
      cidr_range = "10.134.0.0/24"

      type     = "f1-micro"
      replicas = 1
      zones    = ["southamerica-east1-b"]
    }

    "us-east1" = {
      cidr_range = "10.136.0.0/24"

      type     = "f1-micro"
      replicas = 1
      zones    = ["us-east1-d"]
    }

    "us-west2" = {
      cidr_range = "10.137.0.0/24"

      type     = "f1-micro"
      replicas = 1
      zones    = ["us-west2-b"]
    }

    "us-central1" = {
      cidr_range = "10.135.0.0/24"

      type     = "f1-micro"
      replicas = 1
      zones    = ["us-central1-b"]
    }
  }

  container_registry = module.google-artifact-registry.url

  image_repo = module.google-artifact-registry.repo
  image      = "relay"
  image_tag  = var.image_tag

  observability_log_level = "debug,firezone_relay=debug,hyper=off,h2=warn,tower=warn,wire=debug"

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
