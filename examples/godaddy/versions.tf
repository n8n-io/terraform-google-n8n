terraform {
  required_version = ">= 1.11"

  required_providers {
    google = {
      source = "hashicorp/google"
      # >= 6.23 for google_sql_user's password_wo / password_wo_version
      # (postgres_password_write_only).
      version = "~> 6.23"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.23"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    godaddy-dns = {
      source = "veksh/godaddy-dns"
      # Pinned to the 0.3.x line: the veksh/godaddy-dns community provider is
      # still on its 0.x release train, so minor bumps may be breaking.
      # Re-evaluate when 1.0 ships.
      version = "~> 0.3"
    }
  }
}
