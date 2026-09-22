variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "gcp_region" {
  description = "GCP region (e.g. us-east4, us-east1, europe-west1)."
  type        = string
  default     = "us-east4"
}

variable "friendly_name_prefix" {
  description = "Prefix used to derive the name of every Google Cloud resource the module still creates."
  type        = string
  default     = "dev"
}

variable "n8n_fqdn" {
  description = "Hostname n8n is served on."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key (multi-main requires Enterprise)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "n8n_main_hpa_min_replicas" {
  description = "Minimum replica count for n8n main pods, passed straight through to the module's own n8n_main_hpa_min_replicas. Leave null (the default) to use the module's default of 2 (multi-main). Set to 1 to run single-main queue mode instead; see the module's n8n_main_hpa_enabled description for the required license edition and maintenance implications."
  type        = number
  default     = null
}

variable "existing_gcs_bucket_name" {
  description = "Name of the existing GCS bucket used for n8n binary storage."
  type        = string
}

variable "gcs_hmac_service_account_email" {
  description = "Email of the pre-existing service account that owns the out-of-band-created HMAC key. The module grants this account objectAdmin on existing_gcs_bucket_name; it does not create the account or the key."
  type        = string
}

variable "gcs_hmac_access_id" {
  description = "HMAC access ID (S3 access key) for the pre-existing key named by gcs_hmac_service_account_email."
  type        = string
}

variable "gcs_hmac_secret_name" {
  description = "Name of an existing Kubernetes Secret (in the n8n namespace) holding the HMAC secret under key \"accessSecret\". Create this Secret out of band before applying; the module never reads its value."
  type        = string
}

variable "cloud_dns_zone_name" {
  description = "Google Cloud DNS managed-zone name for n8n_fqdn. Empty means you manage the A-record yourself against the static_ip output."
  type        = string
  default     = ""
}

# ── Teardown controls (safe defaults) ─────────────────────────────────────────

variable "gke_deletion_protection" {
  description = "Block terraform destroy of the GKE cluster."
  type        = bool
  default     = true
}

variable "postgres_deletion_protection" {
  description = "Block terraform destroy of the Cloud SQL instance."
  type        = bool
  default     = true
}

# ── Backup tuning passthrough ──────────────────────────────────────────────

variable "postgres_backup_retained_backups" {
  description = "Number of automated backups Cloud SQL retains. Null (the default) preserves the provider's own default retention. Passed straight through to the module's postgres_backup_retained_backups."
  type        = number
  default     = null
}

variable "postgres_transaction_log_retention_days" {
  description = "Days of transaction logs Cloud SQL retains for point-in-time recovery. Null (the default) preserves the provider's own default. Passed straight through to the module's postgres_transaction_log_retention_days."
  type        = number
  default     = null
}

variable "n8n_additional_domains" {
  description = "Additional hostnames to give the full main/webhook route set alongside n8n_fqdn. Passed straight through to the module's n8n_additional_domains. Default empty (no aliases)."
  type        = list(string)
  default     = []
}
