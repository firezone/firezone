terraform {
  required_version = "1.5.6"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }

    google = {
      source  = "hashicorp/google"
      version = "~> 4.81"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 4.81"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
