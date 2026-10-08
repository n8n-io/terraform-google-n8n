# ── Terraform & provider requirements ──────────────────────────────────────
# Declares the minimum Terraform CLI and the providers this module needs.
# Provider configuration (region, auth, kube/helm wiring) is the caller's job
# (see examples/small/providers.tf).

terraform {
  # >= 1.9 for stable cross-variable references in validation blocks; the module
  # also uses dynamic blocks and optional() object attributes.
  required_version = ">= 1.9"

  required_providers {
    # GCP substrate: GKE, Cloud SQL, Memorystore, GCS, networking, IAM, DNS.
    # >= 6.1: google_container_cluster.secret_manager_config (gke.tf) does not
    # exist in 6.0.x, and Terraform rejects an unknown block at validate time
    # even when it renders with the add-on disabled.
    google = {
      source  = "hashicorp/google"
      version = "~> 6.1"
    }
    # Materializes Google-managed service agents before CMEK IAM grants.
    # Kept in lockstep with google (docs/versioning.md).
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    # Apply the GKE Ingress CRs (BackendConfig/FrontendConfig/ManagedCertificate).
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    # Self-signed cert for tls_mode = self_signed.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
