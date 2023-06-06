## Router and Cloud NAT are required for instances without external IP address
resource "google_compute_router" "default" {
  project = module.google-cloud-project.project.project_id

  name    = module.google-cloud-vpc.name
  network = module.google-cloud-vpc.self_link
  region  = local.region
}

resource "google_compute_router_nat" "application" {
  project = module.google-cloud-project.project.project_id

  name   = module.google-cloud-vpc.name
  region = local.region

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
