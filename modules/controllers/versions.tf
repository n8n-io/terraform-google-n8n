# ── Terraform & provider requirements ──────────────────────────────────────
# Declares the minimum Terraform CLI and the providers this submodule needs.
# Provider configuration is the caller's job: the root module and direct
# callers both pass their existing helm/kubernetes provider configurations
# through implicit inheritance (no configuration_aliases are declared here),
# consistent with the single-configuration-per-provider pattern used
# throughout the root module.

terraform {
  required_version = ">= 1.11"

  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
  }
}
