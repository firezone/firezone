output "master_instance_ip_address" {
  value = google_sql_database_instance.master.private_ip_address
}

output "master_instance_name" {
  value = google_sql_database_instance.master.name
}

output "master_instance_address" {
  value = google_sql_database_instance.master.private_ip_address
}

output "read-replicas" {
  value = google_sql_database_instance.read-replica
}

output "bi_instance_ip_address" {
  value = try(google_sql_database_instance.read-replica[var.database_read_replica_locations[0].region].ip_address[0], google_sql_database_instance.master.private_ip_address)
}
