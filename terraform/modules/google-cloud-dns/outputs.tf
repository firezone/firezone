output "name_servers" {
  value = join(" ", google_dns_managed_zone.main.name_servers)
}

output "zone_name" {
  value = google_dns_managed_zone.main.name
}

output "dns_name" {
  value = google_dns_managed_zone.main.dns_name
}
