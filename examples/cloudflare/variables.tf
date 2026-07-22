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

variable "cluster_name" {
  description = "Name prefix for the GKE cluster and derived resources."
  type        = string
  default     = "n8n-dev"
}

variable "n8n_domain" {
  description = "Hostname n8n is served on (must be in the Cloudflare zone)."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key."
  type        = string
  default     = ""
  sensitive   = true
}

# ── Cloudflare + ACME ─────────────────────────────────────────────────────────

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID that owns n8n_domain."
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (scope: Zone.DNS Edit). Manages the A-record and answers the ACME DNS-01 challenge."
  type        = string
  sensitive   = true
}

variable "acme_email" {
  description = "Email for the Let's Encrypt ACME account."
  type        = string
}

variable "acme_server" {
  description = "ACME directory URL. Default is Let's Encrypt production; use the staging URL while testing to avoid rate limits."
  type        = string
  default     = "https://acme-v02.api.letsencrypt.org/directory"
}

variable "cert_manager_version" {
  description = "cert-manager Helm chart version."
  type        = string
  default     = "v1.16.2"
}

variable "manage_sa_key_org_policy" {
  description = "Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise."
  type        = bool
  default     = false
}

# ── Teardown controls (safe defaults) ─────────────────────────────────────────
# To `terraform destroy`, first flip these (e.g. `-var cluster_deletion_protection=false
# -var cloudsql_deletion_protection=false -var gcs_force_destroy=true`) and apply,
# then destroy.

variable "cluster_deletion_protection" {
  description = "Block terraform destroy of the GKE cluster."
  type        = bool
  default     = true
}

variable "cloudsql_deletion_protection" {
  description = "Block terraform destroy of the Cloud SQL instance."
  type        = bool
  default     = true
}

variable "gcs_force_destroy" {
  description = "Allow terraform destroy to delete the (non-empty) GCS bucket."
  type        = bool
  default     = false
}
