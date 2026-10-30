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
  description = "Public hostname n8n's webhooks are served on. Reachable through the public ingress (google_compute_global_address.public); passed to the module as n8n_webhook_url so N8N_WEBHOOK_URL (and the legacy WEBHOOK_URL on images older than n8n 2.30.0) resolves externally while the editor stays private."
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

# ── TLS-inspecting / TLS-terminating proxy passthrough ─────────────────────
variable "n8n_extra_ca_pem" {
  description = "PEM-encoded CA certificate(s) every n8n role should trust for outbound TLS, for a TLS-inspecting egress proxy or a private CA. Passed straight through to the module's n8n_extra_ca_pem. Certificates only, no private keys. Null (the default) adds nothing. See https://github.com/n8n-io/terraform-google-n8n/blob/main/docs/tls-proxy.md."
  type        = string
  default     = null
}

variable "n8n_proxy_hops" {
  description = "Number of trusted reverse-proxy hops in front of n8n (N8N_PROXY_HOPS), passed through to the module's n8n_proxy_hops. One value applies to every n8n role and to both of this example's ingresses. Each Google Cloud load balancer appends two X-Forwarded-For entries, so each path needs 2 with no customer proxy in front. Behind one customer proxy, the external load balancer path needs 3. The internal load balancer strips an X-Forwarded-For it receives from an intermediate proxy, so behind a proxy n8n sees the proxy's address on the editor path whatever the count. Verify the address n8n records on both paths before you rely on client-IP logging or rate limits. Restrict both load balancers to the proxy's egress addresses, or a client that bypasses the proxy can choose its own client IP. Null (the default) leaves n8n's own default. See https://github.com/n8n-io/terraform-google-n8n/blob/main/docs/tls-proxy.md."
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
