variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "gcp_region" {
  description = "GCP region (e.g. us-east4, us-east1, europe-west1)."
  type        = string
  default     = "us-east4"
}

variable "gcs_location" {
  description = "GCS bucket location for binary storage. Keep it near gcp_region (e.g. US for a us-* region, EU for europe-*)."
  type        = string
  default     = "US"
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

variable "redis_host" {
  description = "External Redis-compatible host n8n and KEDA connect to."
  type        = string
}

variable "redis_port" {
  description = "External Redis port."
  type        = number
  default     = 6379
}

variable "redis_tls_enabled" {
  description = "Whether n8n and KEDA connect to redis_host over TLS."
  type        = bool
  default     = true
}

variable "redis_username" {
  description = "Optional ACL username for the external Redis host (Redis 6+ ACL-compatible services). Leave null if the service does not use ACL usernames."
  type        = string
  default     = null
}

variable "redis_password_secret_name" {
  description = "Name of an existing Kubernetes Secret (in the n8n namespace) holding the external Redis password under key \"password\". Create this Secret out of band before applying; the module never reads its value."
  type        = string
}

variable "cloud_dns_zone_name" {
  description = "Google Cloud DNS managed-zone name for n8n_fqdn. Empty means you manage the A-record yourself against the static_ip output."
  type        = string
  default     = ""
}

variable "manage_sa_key_org_policy" {
  description = "Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise."
  type        = bool
  default     = false
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

variable "gcs_force_destroy" {
  description = "Allow terraform destroy to delete the (non-empty) GCS bucket."
  type        = bool
  default     = false
}
