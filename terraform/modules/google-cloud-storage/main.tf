resource "google_project_service" "storage-api" {
  project = var.project_id

  service = "storage-api.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "storage-component" {
  project = var.project_id

  service = "storage-component.googleapis.com"

  disable_on_destroy = false
}
