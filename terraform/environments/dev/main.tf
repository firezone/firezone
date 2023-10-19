locals {
  project_owners = [
    "a@firezone.dev",
    "bmanifold@firezone.dev",
    "gabriel@firezone.dev",
    "jamil@firezone.dev",
    "thomas@firezone.dev"
  ]

  region            = "us-east1"
  availability_zone = "us-east1-d"

  tld = "firez.one"
}

terraform {
  cloud {
    organization = "firezone"
    hostname     = "app.terraform.io"

    workspaces {
      name = "dev"
    }
  }
}

provider "random" {}
provider "null" {}
provider "google" {}
provider "google-beta" {}

# Create the project
module "google-cloud-project" {
  source = "../../modules/google-cloud-project"

  id                 = "firezone-dev"
  name               = "Dev Environment"
  organization_id    = "335836213177"
  billing_account_id = "01DFC9-3D6951-579BE1"
}

# Grant owner access to the project
resource "google_project_iam_binding" "project_owners" {
  project = module.google-cloud-project.project.project_id
  role    = "roles/owner"
  members = formatlist("user:%s", local.project_owners)
}

# Enable Google Cloud Storage for the project
module "google-cloud-storage" {
  source = "../../modules/google-cloud-storage"

  project_id = module.google-cloud-project.project.project_id
}

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
