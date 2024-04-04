output "dns_name_servers" {
  value = module.google-cloud-dns.name_servers
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
