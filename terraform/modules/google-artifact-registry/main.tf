resource "google_project_service" "artifactregistry" {
  project = var.project_id
  service = "artifactregistry.googleapis.com"

  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "firezone" {
  provider = google-beta
  project  = var.project_id

  location      = var.region
  repository_id = "firezone"
  description   = "Repository for storing Docker images in the ${var.project_name}."

  format = "DOCKER"

  docker_config {
    immutable_tags = var.immutable_tags
  }

  cleanup_policies {
    id     = "keep-latest-release"
    action = "KEEP"

    condition {
      tag_state    = "TAGGED"
      tag_prefixes = ["latest"]
    }
  }

  cleanup_policies {
    id     = "keep-minimum-versions"
    action = "KEEP"

    most_recent_versions {
      keep_count = 5
    }
  }

  cleanup_policies {
    id     = "gc-untagged"
    action = "DELETE"

    condition {
      tag_state  = "UNTAGGED"
      older_than = "90d"
    }
  }

  cleanup_policies {
    id     = "gc-cache"
    action = "DELETE"

    condition {
      tag_state             = "ANY"
      package_name_prefixes = ["cache/"]
      older_than            = "30d"
    }
  }

  dynamic "cleanup_policies" {
    for_each = var.store_tagged_artifacts_for != null ? [1] : []

    content {
      id     = "gc-expired-artifacts"
      action = "DELETE"

      condition {
        tag_state  = "TAGGED"
        older_than = var.store_tagged_artifacts_for
      }
    }
  }

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
