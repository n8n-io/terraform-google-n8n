# ── Terraform & provider requirements ──────────────────────────────────────
# Declares the minimum Terraform CLI and the providers this module needs.
# Provider configuration (region, auth, kube/helm wiring) is the caller's job
# (see examples/small/providers.tf).

terraform {
  # >= 1.9 was sufficient for stable cross-variable references in validation
  # blocks (the module also uses dynamic blocks and optional() object
  # attributes), but the postgres_password_write_only opt-in (cloudsql.tf)
  # raises the floor to >= 1.11: an `ephemeral = true` variable
  # (postgres_password_wo) needs Terraform 1.10's ephemeral-value support,
  # and feeding it into google_sql_user.n8n's password_wo argument needs
  # 1.11's write-only-argument support for managed resources. Both are
  # parsed unconditionally from this module's HCL regardless of whether any
  # caller sets postgres_password_write_only, so the floor is module-wide.
  required_version = ">= 1.11"

  required_providers {
    # GCP substrate: GKE, Cloud SQL, Memorystore, GCS, networking, IAM, DNS.
    google = {
      source = "hashicorp/google"
      # >= 6.23 for google_sql_user's password_wo / password_wo_version
      # (postgres_password_write_only, cloudsql.tf). Kept within the same
      # 6.x major.
      version = "~> 6.23"
    }
    # Materializes Google-managed service agents before CMEK IAM grants.
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
