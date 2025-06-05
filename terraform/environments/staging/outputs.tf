output "dns_name_servers" {
  value = module.google-cloud-dns.name_servers
}

output "demo_postgresql_instance_ip" {
  sensitive = true
  value     = module.google-cloud-sql.master_instance_ip_address
}

output "demo_postgresql_connection_url" {
  sensitive = true
  value     = "postgres://${google_sql_user.demo.name}:${random_password.demo_db_password.result}@${module.google-cloud-sql.master_instance_ip_address}/${google_sql_database.demo.name}"
}

output "image_tag" {
  value = var.image_tag
}

output "gateway_image_tag" {
  value = local.gateway_image_tag
}

output "relay_image_tag" {
  value = local.relay_image_tag
}

output "portal_image_tag" {
  value = local.portal_image_tag
}
