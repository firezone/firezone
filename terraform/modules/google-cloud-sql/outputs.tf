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
