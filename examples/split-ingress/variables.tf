variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "gcp_region" {
  description = "GCP region (e.g. us-east4, us-east1, europe-west1). Must support GKE regional internal Application Load Balancing (most regions do)."
  type        = string
  default     = "us-east4"
}

variable "gcs_location" {
  description = "GCS bucket location for binary storage. Keep it near gcp_region (e.g. US for a us-* region, EU for europe-*)."
  type        = string
  default     = "US"
}

variable "friendly_name_prefix" {
  description = "Prefix used to derive the name of every Google Cloud resource this example and the module create."
  type        = string
  default     = "split"
}

variable "n8n_fqdn" {
  description = "Private hostname n8n's editor/API is served on. Reachable only through the internal ingress (google_compute_address.private); not publicly resolvable. Also used as N8N_EDITOR_BASE_URL by the module."
  type        = string
}

variable "public_webhook_fqdn" {
  description = "Public hostname n8n's webhooks are served on. Reachable through the public ingress (google_compute_global_address.public); passed to the module as n8n_webhook_url so WEBHOOK_URL/N8N_WEBHOOK_URL resolve externally while the editor stays private."
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

variable "manage_sa_key_org_policy" {
  description = "Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise."
  type        = bool
  default     = false
}

# ── Split-ingress networking ───────────────────────────────────────────────────

variable "proxy_only_subnet_cidr" {
  description = "CIDR range for the regional proxy-only subnet the internal Application Load Balancer's managed proxies use to reach backends. Must not overlap the module's VPC (network.tf's subnet_cidr/pods_cidr/services_cidr) or this subnet's own firewall rule's source range. See Google's example range in the internal-ingress guide."
  type        = string
  default     = "10.129.0.0/23"
}

# ── TLS (private ingress; public ingress uses a Google-managed certificate) ───

variable "internal_tls_cert_pem" {
  description = "PEM certificate for the private ingress's TLS Secret, covering n8n_fqdn. GKE's internal Application Load Balancer does not provision Google-managed certificates, so this is a caller-supplied prerequisite (e.g. from an internal CA); the module and this example never generate or self-sign it."
  type        = string
  sensitive   = true
}

variable "internal_tls_key_pem" {
  description = "PEM private key corresponding to internal_tls_cert_pem."
  type        = string
  sensitive   = true
}

# ── Teardown controls (safe defaults) ─────────────────────────────────────────
# To `terraform destroy`, first flip these (e.g. `-var gke_deletion_protection=false
# -var postgres_deletion_protection=false -var gcs_force_destroy=true`) and apply,
# then destroy.

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

# ── Backup tuning passthrough ─────────────────────────────────────────────────

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
