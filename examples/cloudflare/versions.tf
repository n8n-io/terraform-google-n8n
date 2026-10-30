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
    cloudflare = {
      source = "cloudflare/cloudflare"
      # Floor 4.39: cloudflare_record.content (used in dns.tf) was introduced
      # in 4.39.0 (value -> content rename); earlier 4.x fails validation.
      version = "~> 4.39"
    }
  }
}
