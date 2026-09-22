# ── Example: customer-managed-gcs ──────────────────────────────────────────────
# GCS ownership boundary only: the module points n8n's S3-compatible binary
# storage driver at an existing bucket and an existing, out-of-band-created
# HMAC key (BYO HMAC), instead of creating the bucket and HMAC identity
# itself. Every other layer (VPC, GKE, Cloud SQL, Memorystore, ingress, DNS)
# stays module-managed, same as examples/small.
#
# The HMAC secret is supplied via an existing Kubernetes Secret
# (gcs_hmac_secret_name), so it never enters Terraform state; create the
# bucket, service account, HMAC key, and Secret out of band before applying
# (see README.md).

module "n8n" {
  source = "../.."

  project_id           = var.project_id
  gcp_region           = var.gcp_region
  friendly_name_prefix = var.friendly_name_prefix
  n8n_fqdn             = var.n8n_fqdn

  n8n_license_key = var.n8n_license_key

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  # ── GCS ownership: existing bucket + BYO HMAC identity ─────────────────────
  create_gcs_bucket              = false
  existing_gcs_bucket_name       = var.existing_gcs_bucket_name
  gcs_hmac_service_account_email = var.gcs_hmac_service_account_email
  gcs_hmac_access_id             = var.gcs_hmac_access_id
  gcs_hmac_secret_name           = var.gcs_hmac_secret_name

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  gke_deletion_protection      = var.gke_deletion_protection
  postgres_deletion_protection = var.postgres_deletion_protection

  # ── Backup tuning passthrough ──────────────────────────────────────────────
  postgres_backup_retained_backups        = var.postgres_backup_retained_backups
  postgres_transaction_log_retention_days = var.postgres_transaction_log_retention_days

  # DNS + TLS: manage the record in Cloud DNS, Google-managed cert.
  cloud_dns_zone_name    = var.cloud_dns_zone_name
  tls_mode               = "google_managed"
  n8n_additional_domains = var.n8n_additional_domains
}
