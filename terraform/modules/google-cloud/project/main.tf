
resource "google_project" "project" {
  name = var.name

  org_id          = var.organization_id
  billing_account = var.billing_account_id
  project_id      = var.id != "" ? var.id : replace(lower(var.name), " ", "-")

  auto_create_network = var.auto_create_network
}

resource "google_project_service" "oslogin" {
  project = google_project.project.project_id
  service = "oslogin.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  project = google_project.project.project_id
  service = "iam.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "iamcredentials" {
  project = google_project.project.project_id
  service = "iamcredentials.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "serviceusage" {
  project = google_project.project.project_id
  service = "serviceusage.googleapis.com"

  disable_on_destroy = false
}
