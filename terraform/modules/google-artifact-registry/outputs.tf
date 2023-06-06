output "name" {
  value = google_artifact_registry_repository.firezone.name
}

output "url" {
  value = "${var.region}-docker.pkg.dev"
}

output "repo" {
  value = "${var.project_id}/${google_artifact_registry_repository.firezone.name}"
}
