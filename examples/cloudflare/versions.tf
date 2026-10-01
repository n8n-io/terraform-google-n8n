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
    cloudflare = {
      source = "cloudflare/cloudflare"
      # Floor 4.39: cloudflare_record.content (used in dns.tf) was introduced
      # in 4.39.0 (value -> content rename); earlier 4.x fails validation.
      version = "~> 4.39"
    }
  }
}
