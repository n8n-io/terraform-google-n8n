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
  default     = "medium"
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

variable "n8n_image_tag" {
  description = "n8n image tag to deploy, passed straight through to the module's n8n_image_tag. Null (the default) keeps the chart's own default tag: its appVersion (2.41.4 at chart 1.14.0), which only moves when the module's n8n_chart_version does. Pin a concrete version (for example \"2.39.7\") to upgrade n8n independently of the chart."
  type        = string
  default     = null
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

# ── Sizing profile: MEDIUM ────────────────────────────────────────────────────
# Steady production / moderate load. Larger than the module defaults (small):
# a general-purpose Cloud SQL tier + HA Memorystore, bigger nodes, and higher
# autoscaling ceilings. NOT scale-validated; tune against a load test.

variable "postgres_machine_type" {
  description = "Cloud SQL machine tier (ENTERPRISE edition)."
  type        = string
  default     = "db-custom-4-15360" # 4 vCPU / 15 GB
}

variable "postgres_disk_size" {
  description = "Cloud SQL data disk size in GB."
  type        = number
  default     = 100
}

variable "postgres_availability_type" {
  description = "REGIONAL (HA failover) or ZONAL."
  type        = string
  default     = "REGIONAL"
}

variable "redis_tier" {
  description = "Memorystore tier: BASIC or STANDARD_HA."
  type        = string
  default     = "STANDARD_HA"
}

variable "n8n_redis_timeout_threshold_ms" {
  description = "Milliseconds n8n waits for a Redis response before treating the connection as failed. Must be at least 30000 (30s) when redis_tier = STANDARD_HA."
  type        = number
  default     = 30000
}

variable "redis_memory_size_gb" {
  description = "Memorystore capacity in GB."
  type        = number
  default     = 4
}

variable "gke_node_type" {
  description = "GKE node machine type."
  type        = string
  default     = "e2-standard-8"
}

variable "gke_node_min_per_zone" {
  description = "Autoscaling min nodes per zone (regional cluster ~3 zones)."
  type        = number
  default     = 2
}

variable "gke_node_max_per_zone" {
  description = "Autoscaling max nodes per zone."
  type        = number
  default     = 5
}

variable "gke_node_disk_size_gb" {
  description = "Node boot disk size in GB, passed straight through to the module. Defaults to the module's own default of 100."
  type        = number
  default     = 100
}

variable "gke_node_disk_type" {
  description = "Node boot disk type (pd-standard, pd-balanced, pd-ssd), passed straight through to the module. Defaults to the module's own default of pd-balanced."
  type        = string
  default     = "pd-balanced"
}

variable "n8n_worker_concurrency" {
  description = "Concurrent executions per worker pod."
  type        = number
  default     = 15
}

variable "db_postgresdb_pool_size" {
  description = "Maximum TypeORM connection pool slots per n8n pod, passed straight through to the module. Defaults to the module's own default of 10, which already covers this tier's rule-of-thumb floor of n8n_worker_concurrency / 4 (15 / 4 = 3.75); raise it only after a load test shows pool exhaustion."
  type        = number
  default     = 10
}

variable "n8n_worker_keda_min_replicas" {
  description = "KEDA worker floor."
  type        = number
  default     = 2
}

variable "n8n_worker_keda_max_replicas" {
  description = "KEDA worker ceiling (pair with gke_node_max_per_zone)."
  type        = number
  default     = 30
}

variable "n8n_main_hpa_min_replicas" {
  description = "Main-pod HPA floor, passed straight through to the module. Defaults to the module's own default of 2 (multi-main) so this tier's sizing does not silently diverge; set to 1 for single-main queue mode instead (see the module's n8n_main_hpa_enabled description for licensing and maintenance implications)."
  type        = number
  default     = 2
  nullable    = false
}

variable "n8n_webhook_hpa_min_replicas" {
  description = "Webhook-processor HPA floor."
  type        = number
  default     = 3
}

variable "n8n_webhook_hpa_max_replicas" {
  description = "Webhook-processor HPA ceiling."
  type        = number
  default     = 40
}

variable "n8n_execution_concurrency_limit" {
  description = "n8n production execution concurrency limit."
  type        = number
  default     = 200
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
