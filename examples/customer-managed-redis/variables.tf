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

variable "n8n_main_hpa_min_replicas" {
  description = "Minimum replica count for n8n main pods, passed straight through to the module's own n8n_main_hpa_min_replicas. Leave null (the default) to use the module's default of 2 (multi-main). Set to 1 to run single-main queue mode instead; see the module's n8n_main_hpa_enabled description for the required license edition and maintenance implications."
  type        = number
  default     = null
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

# ── TLS-inspecting / TLS-terminating proxy passthrough ─────────────────────
variable "n8n_extra_ca_pem" {
  description = "PEM-encoded CA certificate(s) every n8n role should trust for outbound TLS, for a TLS-inspecting egress proxy or a private CA. Passed straight through to the module's n8n_extra_ca_pem. Certificates only, no private keys. Null (the default) adds nothing. See https://github.com/n8n-io/terraform-google-n8n/blob/main/docs/tls-proxy.md."
  type        = string
  default     = null
}

variable "n8n_proxy_hops" {
  description = "Number of trusted reverse-proxy hops in front of n8n (N8N_PROXY_HOPS), passed straight through to the module's n8n_proxy_hops. The Google Cloud load balancer appends two X-Forwarded-For entries, so it counts as 2, and one customer proxy in front of the module's ingress is 3. Too low a value attributes every request to the proxy's address. Admit only the proxy's egress addresses with the module's ingress_source_cidrs, which this example does not pass through (add it in main.tf); otherwise a client that bypasses the proxy can choose its own client IP. Null (the default) leaves n8n's own default. See https://github.com/n8n-io/terraform-google-n8n/blob/main/docs/tls-proxy.md."
  type        = number
  default     = null
}

variable "n8n_extra_env" {
  description = "Additional environment variables for the n8n container in every main, worker, and webhook-processor pod, passed straight through to the module's n8n_extra_env. Use it for HTTPS_PROXY, HTTP_PROXY and NO_PROXY behind an egress proxy (see https://github.com/n8n-io/terraform-google-n8n/blob/main/docs/tls-proxy.md). The module's input is meant for non-secret values, because values are stored in plain text in Terraform state and the Helm release. The documented exception is the credentials in an authenticated proxy URL. This example marks the variable sensitive to redact normal plan and apply output; values remain readable in Terraform state and the Helm release values."
  type = list(object({
    name  = string
    value = string
  }))
  default   = []
  sensitive = true
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

variable "n8n_additional_domains" {
  description = "Additional hostnames to give the full main/webhook route set alongside n8n_fqdn. Passed straight through to the module's n8n_additional_domains. Default empty (no aliases)."
  type        = list(string)
  default     = []
}
