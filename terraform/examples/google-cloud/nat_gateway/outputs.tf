output "static_ip_addresses" {
  value = [google_compute_address.ipv4.address]
}
