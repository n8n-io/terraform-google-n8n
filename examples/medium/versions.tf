terraform {
  required_version = ">= 1.13"

  required_providers {
    google = {
      source = "hashicorp/google"
      # ~> 8.0 matches the root module's constraint (see its versions.tf);
      # the module was checked against google provider v8.7.0.
      version = "~> 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.0"
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
  }
}
