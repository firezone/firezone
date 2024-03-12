resource "google_compute_network" "firezone" {
  name                    = "firezone-gateway"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute-api]
}

resource "google_compute_subnetwork" "firezone" {
  name          = "firezone-subnet"
  network       = google_compute_network.firezone.id
  ip_cidr_range = var.firezone_subnet_cidr
  region        = var.region
}

resource "google_compute_router" "firezone" {
  name    = "firezone-gateway-router"
  network = google_compute_network.firezone.id
}

resource "google_compute_address" "firezone" {
  name   = "firezone-nat-address"
  region = var.region
}

resource "google_compute_router_nat" "firezone" {
  name   = "firezone-gateway-nat"
  router = google_compute_router.firezone.name

  nat_ip_allocate_option = "MANUAL_ONLY"
  nat_ips                = [google_compute_address.firezone.self_link]

  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.firezone.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

// Allow SSH access to the gateways. This is optional but helpful for debugging
// and administration of the gateways. Since they're not publicly accessible,
// you need to tunnel through IAP:
//
//   gcloud compute ssh --tunnel-through-iap --project <PROJECT_ID> --zone <ZONE> gateway-0
resource "google_compute_firewall" "ssh-rule" {
  name    = "allow-ssh"
  network = google_compute_network.firezone.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  target_tags   = ["firezone-gateway"]
  source_ranges = ["35.235.240.0/20"] // IAP CIDR
}
