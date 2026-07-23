variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "gcp_region" {
  description = "GCP region (e.g. us-east4, us-east1, europe-west3)."
  type        = string
  default     = "us-east4"
}

variable "gcs_location" {
  description = "GCS bucket location for binary storage. Keep it near gcp_region (e.g. US for a us-* region, EU for europe-*)."
  type        = string
  default     = "US"
}

variable "friendly_name_prefix" {
  description = "Prefix used to derive the name of every Google Cloud resource the module creates."
  type        = string
  default     = "godaddy"
}

variable "n8n_domain" {
  description = "Hostname n8n is served on. Must be within godaddy_domain."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key."
  type        = string
  default     = ""
  sensitive   = true
}

# ── GoDaddy DNS ───────────────────────────────────────────────────────────────
variable "godaddy_domain" {
  description = "The GoDaddy zone (registered domain) that owns n8n_domain, e.g. example.com."
  type        = string
}

variable "godaddy_api_key" {
  description = "GoDaddy API key. Can also be supplied via the GODADDY_API_KEY environment variable. Create one at https://developer.godaddy.com/keys."
  type        = string
  default     = ""
  sensitive   = true
}

variable "godaddy_api_secret" {
  description = "GoDaddy API secret corresponding to godaddy_api_key. Can also be supplied via the GODADDY_API_SECRET environment variable."
  type        = string
  default     = ""
  sensitive   = true
}

variable "manage_sa_key_org_policy" {
  description = "Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation on the project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise."
  type        = bool
  default     = false
}

# ── Teardown controls (safe defaults) ─────────────────────────────────────────
# For `terraform destroy`, first flip these (e.g. -var cluster_deletion_protection=false
# -var postgres_deletion_protection=false -var gcs_force_destroy=true) and apply,
# then destroy.
variable "cluster_deletion_protection" {
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
  description = "Allow terraform destroy to delete the GCS bucket even if it still holds objects."
  type        = bool
  default     = false
}
