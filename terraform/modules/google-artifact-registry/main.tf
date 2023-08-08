resource "google_project_service" "artifactregistry" {
  project = var.project_id
  service = "artifactregistry.googleapis.com"

  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "firezone" {
  project = var.project_id

  location      = var.region
  repository_id = "firezone"
  description   = "Repository for storing Docker images in the ${var.project_name}."

  format = "DOCKER"

  depends_on = [
    google_project_service.artifactregistry
  ]
}

data "google_iam_policy" "artifacts_policy" {
  binding {
    role    = "roles/artifactregistry.reader"
    members = ["allUsers"]
  }

  binding {
    role    = "roles/artifactregistry.writer"
    members = var.writers
  }
}

resource "google_artifact_registry_repository_iam_policy" "policy" {
  project    = google_artifact_registry_repository.firezone.project
  location   = google_artifact_registry_repository.firezone.location
  repository = google_artifact_registry_repository.firezone.name

  policy_data = data.google_iam_policy.artifacts_policy.policy_data
}
