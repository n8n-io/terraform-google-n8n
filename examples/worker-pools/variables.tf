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
  description = "Prefix used to derive the name of every Google Cloud resource the module creates."
  type        = string
  default     = "dev"
}

variable "n8n_fqdn" {
  description = "Hostname n8n is served on."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Must carry feat:workerPools (see README.md); multi-main additionally needs feat:multipleMainInstances."
  type        = string
  sensitive   = true
}

variable "n8n_image_tag" {
  description = "n8n image tag to deploy, passed straight through to the module's n8n_image_tag. Required by this example (no default): worker pools need n8n >= 2.39.0, which predates the chart's floating `stable` tag at the time of writing. See README.md."
  type        = string
}

variable "cloud_dns_zone_name" {
  description = "Google Cloud DNS managed-zone name for n8n_fqdn. Empty means you manage the A-record yourself against the static_ip output."
  type        = string
  default     = ""
}

variable "n8n_main_hpa_min_replicas" {
  description = "Minimum replica count for n8n main pods, passed straight through to the module's own n8n_main_hpa_min_replicas. Leave null (the default) to use the module's default of 2 (multi-main, needs feat:multipleMainInstances on top of feat:workerPools). Set to 1 to run single-main queue mode instead."
  type        = number
  default     = null
}

variable "manage_sa_key_org_policy" {
  description = "Opt-in: let Terraform turn OFF iam.disableServiceAccountKeyCreation for this project so the GCS HMAC key can be created. Requires roles/orgpolicy.policyAdmin. Default false; disable the policy out-of-band otherwise."
  type        = bool
  default     = false
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

# ── Node capacity ────────────────────────────────────────────────────────────
# See main.tf's comment on gke_node_max_per_zone for the arithmetic behind the
# default bump from the module's own default of 4.
variable "gke_node_max_per_zone" {
  description = "Autoscaling maximum GKE nodes per zone, passed straight through to the module's gke_node_max_per_zone. The three worker pools this example declares are additional autoscalers on the same node pool, not a redistribution of the ceilings already there, so this defaults higher than the module's own default of 4. See main.tf."
  type        = number
  default     = 6
}

# ── Worker pools (EARLY ALPHA) ───────────────────────────────────────────────

variable "n8n_chart_version" {
  description = "n8n Helm chart version to deploy, passed to the module's n8n_chart_version. Required by this example because the module default predates queueMode.workerGroups and would render no pools. Pin a worker-pools preview build (a prerelease whose identifier contains \"workerpools\", e.g. 1.11.0-preview.workerpools.1, published to n8n_chart_repository's default via n8n-io/n8n-hosting's Preview chart GitHub Action, or to a registry you control) until a numbered release carries the feature. See README.md, \"Getting a chart that renders pools\"."
  type        = string
}

variable "n8n_chart_repository" {
  description = "Helm chart repository the module pulls the n8n chart from, passed to the module's n8n_chart_repository. The default is the module's own default, the public upstream registry, which is right both once a released chart renders pools and while using an official prerelease build published there. Only override this to point at a registry you control, e.g. Artifact Registry, if you packaged and pushed a preview build yourself."
  type        = string
  default     = "oci://ghcr.io/n8n-io/n8n-helm-chart"
}

variable "n8n_worker_pools_chart_verified" {
  description = "Attests that n8n_chart_version renders queueMode.workerGroups, passed straight through to the module's n8n_worker_pools_chart_verified. Only needed for a chart version that is not a worker-pools preview build (a numbered release or generic prerelease on a private mirror you have already verified); a prerelease whose identifier contains \"workerpools\" is taken at your word from the version string itself. Leave false (the default) while pinning the official preview build."
  type        = bool
  default     = false
}

variable "n8n_worker_keda_min_replicas" {
  description = "Minimum replicas for the chart's own unlabelled worker deployment (the default `jobs` queue), passed straight through to the module's n8n_worker_keda_min_replicas."
  type        = number
  default     = 1
}

variable "n8n_worker_keda_max_replicas" {
  description = "Maximum replicas for the chart's own unlabelled worker deployment, passed straight through to the module's n8n_worker_keda_max_replicas."
  type        = number
  default     = 10
}

# ── Teardown controls (safe defaults) ────────────────────────────────────────
# To `terraform destroy`, first flip these and apply, then destroy.

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
