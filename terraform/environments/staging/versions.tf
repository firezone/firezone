terraform {
  required_version = "1.6.5"

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
      version = "~> 5.2"
    }

    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.2"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }

    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "1.21.1-beta.1"
    }
  }
}
