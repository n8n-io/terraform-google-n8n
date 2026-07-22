terraform {
  required_version = ">= 1.9"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
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
