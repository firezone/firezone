# Bucket where CI stores binary artifacts (eg. gateway or client)
resource "google_storage_bucket" "firezone-binary-artifacts" {
  project = module.google-cloud-project.project.project_id
  name    = "${module.google-cloud-project.project.project_id}-artifacts"

  location = "US"

  lifecycle_rule {
    condition {
      age = 365
    }

    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 1
    }

    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  public_access_prevention    = "inherited"
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "public-firezone-binary-artifacts" {
  bucket = google_storage_bucket.firezone-binary-artifacts.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Docker layer caching
resource "google_artifact_registry_repository" "cache" {
  provider = google-beta
  project  = module.google-cloud-project.project.project_id

  location      = local.region
  repository_id = "cache"
  description   = "Repository for storing Docker images in the ${module.google-cloud-project.name}."

  format = "DOCKER"

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
      older_than = "${14 * 24 * 60 * 60}s"
    }
  }

  cleanup_policies {
    id     = "gc-cache"
    action = "DELETE"

    condition {
      tag_state  = "ANY"
      older_than = "${30 * 24 * 60 * 60}s"
    }
  }

  depends_on = [
    module.google-artifact-registry
  ]
}

data "google_iam_policy" "caches_policy" {
  binding {
    role    = "roles/artifactregistry.reader"
    members = ["allUsers"]
  }

  binding {
    role    = "roles/artifactregistry.writer"
    members = local.ci_iam_members
  }
}

resource "google_artifact_registry_repository_iam_policy" "policy" {
  project    = google_artifact_registry_repository.cache.project
  location   = google_artifact_registry_repository.cache.location
  repository = google_artifact_registry_repository.cache.name

  policy_data = data.google_iam_policy.caches_policy.policy_data
}

# sccache is used by Rust CI jobs
resource "google_storage_bucket" "sccache" {
  project = module.google-cloud-project.project.project_id
  name    = "${module.google-cloud-project.project.project_id}-sccache"

  location = "US"

  lifecycle_rule {
    condition {
      age = 30
    }

    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 1
    }

    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  public_access_prevention    = "inherited"
  uniform_bucket_level_access = true
}

resource "google_storage_bucket_iam_member" "public-sccache" {
  bucket = google_storage_bucket.sccache.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

resource "google_storage_bucket_iam_member" "github-actions-sccache-access" {
  for_each = toset(local.ci_iam_members)

  bucket = google_storage_bucket.sccache.name
  role   = "roles/storage.objectAdmin"
  member = each.key
}

resource "google_storage_bucket_iam_member" "github-actions-firezone-binary-artifacts-access" {
  for_each = toset(local.ci_iam_members)

  bucket = google_storage_bucket.firezone-binary-artifacts.name
  role   = "roles/storage.objectAdmin"
  member = each.key
}
