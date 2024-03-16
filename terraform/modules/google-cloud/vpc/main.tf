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

## Router and Cloud NAT are required for instances without external IP address
resource "google_compute_router" "default" {
  project = var.project_id

  name    = google_compute_network.vpc_network.name
  network = google_compute_network.vpc_network.self_link
  region  = var.nat_region
}

resource "google_compute_router_nat" "application" {
  project = var.project_id

  name   = google_compute_network.vpc_network.name
  region = var.nat_region

  router = google_compute_router.default.name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  enable_dynamic_port_allocation = false
  min_ports_per_vm               = 32

  udp_idle_timeout_sec             = 30
  icmp_idle_timeout_sec            = 30
  tcp_established_idle_timeout_sec = 1200
  tcp_transitory_idle_timeout_sec  = 30
  tcp_time_wait_timeout_sec        = 120
}
