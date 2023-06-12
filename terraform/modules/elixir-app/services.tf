
resource "google_project_service" "compute" {
  project = var.project_id
  service = "compute.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "pubsub" {
  project = var.project_id
  service = "pubsub.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "bigquery" {
  project = var.project_id
  service = "bigquery.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "container" {
  project = var.project_id
  service = "container.googleapis.com"

  depends_on = [
    google_project_service.compute,
    google_project_service.pubsub,
    google_project_service.bigquery,
  ]

  disable_on_destroy = false
}

resource "google_project_service" "stackdriver" {
  project = var.project_id
  service = "stackdriver.googleapis.com"

  disable_on_destroy = false
}

resource "google_project_service" "logging" {
  project = var.project_id
  service = "logging.googleapis.com"

  disable_on_destroy = false

  depends_on = [google_project_service.stackdriver]
}

resource "google_project_service" "monitoring" {
  project = var.project_id
  service = "monitoring.googleapis.com"

  disable_on_destroy = false

  depends_on = [google_project_service.stackdriver]
}

resource "google_project_service" "clouddebugger" {
  project = var.project_id
  service = "clouddebugger.googleapis.com"

  disable_on_destroy = false

  depends_on = [google_project_service.stackdriver]
}

resource "google_project_service" "cloudprofiler" {
  project = var.project_id
  service = "cloudprofiler.googleapis.com"

  disable_on_destroy = false

  depends_on = [google_project_service.stackdriver]
}

resource "google_project_service" "cloudtrace" {
  project = var.project_id
  service = "cloudtrace.googleapis.com"

  disable_on_destroy = false

  depends_on = [google_project_service.stackdriver]
}

resource "google_project_service" "servicenetworking" {
  project = var.project_id
  service = "servicenetworking.googleapis.com"

  disable_on_destroy = false
}
