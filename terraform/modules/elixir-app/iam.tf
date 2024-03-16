# Create IAM role for the application instances
resource "google_service_account" "application" {
  project = var.project_id

  account_id   = "app-${local.application_name}"
  display_name = "${local.application_name} app"
  description  = "Service account for ${local.application_name} application instances."
}

## Allow application service account to pull images from the container registry
resource "google_project_iam_member" "artifacts" {
  project = var.project_id

  role = "roles/artifactregistry.reader"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow fluentbit to injest logs
resource "google_project_iam_member" "logs" {
  project = var.project_id

  role = "roles/logging.logWriter"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow reporting application errors
resource "google_project_iam_member" "errors" {
  project = var.project_id

  role = "roles/errorreporting.writer"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow reporting metrics
resource "google_project_iam_member" "metrics" {
  project = var.project_id

  role = "roles/monitoring.metricWriter"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow reporting metrics
resource "google_project_iam_member" "service_management" {
  project = var.project_id

  role = "roles/servicemanagement.reporter"

  member = "serviceAccount:${google_service_account.application.email}"
}

## Allow appending traces
resource "google_project_iam_member" "cloudtrace" {
  project = var.project_id

  role = "roles/cloudtrace.agent"

  member = "serviceAccount:${google_service_account.application.email}"
}
