terraform {
  required_version = "~> 1.9.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }

    google = {
      source  = "hashicorp/google"
      version = "~> 5.20"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.20"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "1.24.0"
    }
  }
}
