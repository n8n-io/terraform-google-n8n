# ── Example: customer-managed-cluster ──────────────────────────────────────────
# GKE ownership boundary only: the module deploys onto an existing regional GKE
# cluster instead of creating one. Every other layer (VPC, Cloud SQL,
# Memorystore, GCS, ingress, DNS) stays module-managed, same as examples/small.
#
# Prerequisites the existing cluster must meet are documented in README.md and
# summarized by existing_gke_prerequisites_attestation, which this example
# requires you to set explicitly (no default) rather than silently assuming.

module "n8n" {
  source = "../.."

  project_id           = var.project_id
  gcp_region           = var.gcp_region
  friendly_name_prefix = var.friendly_name_prefix
  n8n_fqdn             = var.n8n_fqdn

  n8n_license_key = var.n8n_license_key
  gcs_location    = var.gcs_location

  manage_sa_key_org_policy = var.manage_sa_key_org_policy

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  # ── GKE ownership: attach to an existing regional cluster ──────────────────
  create_gke                             = false
  existing_gke_cluster_name              = var.existing_gke_cluster_name
  existing_gke_prerequisites_attestation = var.existing_gke_prerequisites_attestation

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  postgres_deletion_protection = var.postgres_deletion_protection
  gcs_force_destroy            = var.gcs_force_destroy

  # ── Backup tuning passthrough ───────────────────────────────────────────────
  postgres_backup_retained_backups        = var.postgres_backup_retained_backups
  postgres_transaction_log_retention_days = var.postgres_transaction_log_retention_days

  # Additional domains alongside n8n_fqdn.
  n8n_additional_domains = var.n8n_additional_domains

  # DNS + TLS: manage the record in Cloud DNS, Google-managed cert.
  cloud_dns_zone_name = var.cloud_dns_zone_name
  tls_mode            = "google_managed"
}
