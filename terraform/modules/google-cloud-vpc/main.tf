resource "google_project_service" "compute" {
  project = var.project_id
  service = "compute.googleapis.com"

  disable_on_destroy = false
}

resource "google_compute_network" "vpc_network" {
  project = var.project_id
  name    = var.name

  routing_mode = "GLOBAL"

  auto_create_subnetworks = false

  depends_on = [
    google_project_service.compute
  ]
}
