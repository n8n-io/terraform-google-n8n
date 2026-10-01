# GCP substrate variables
#
# GCP inputs for the module. Shared, provider-agnostic inputs live in
# variables.tf.

# ── Project and region ──────────────────────────────────────────────────────

variable "project_id" {
  description = "GCP project ID to deploy into."
  type        = string
}

variable "gcp_region" {
  description = "GCP region for regional resources (GKE, Cloud SQL, Memorystore, subnet)."
  type        = string
  default     = "europe-west1"
}

# ── Networking ownership (infrastructure-ownership) ───────────────────────────
# Static, non-null ownership switch: count expressions cannot depend on values
# computed at apply time, so this must stay a plan-known boolean rather than
# being inferred from existing_network_name being null.

variable "create_network" {
  description = "When true (the default), the module creates and manages the VPC, subnetwork, secondary ranges, Cloud Router, and Cloud NAT. Set to false to attach to an existing network; existing_network_name, existing_subnetwork_name, existing_pods_range_name, and existing_services_range_name must then be supplied."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_network_name" {
  description = "Name of the existing VPC network to use. Required when create_network = false. Ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.create_network || var.existing_network_name != null
    error_message = "existing_network_name is required when create_network = false."
  }
}

variable "existing_network_project_id" {
  description = "Host project ID of the existing network, when it lives in a Shared VPC host project different from project_id. Ignored when create_network = true. Defaults to project_id (the network lives in the same project) when left null."
  type        = string
  default     = null
}

variable "existing_subnetwork_name" {
  description = "Name of the existing subnetwork (in gcp_region) that GKE and data services attach to. Required when create_network = false. Ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.create_network || var.existing_subnetwork_name != null
    error_message = "existing_subnetwork_name is required when create_network = false."
  }
}

variable "existing_pods_range_name" {
  description = "Name of the existing secondary IP range on existing_subnetwork_name used for GKE pod alias IPs. Required when create_network = false. Ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.create_network || var.existing_pods_range_name != null
    error_message = "existing_pods_range_name is required when create_network = false."
  }
}

variable "existing_services_range_name" {
  description = "Name of the existing secondary IP range on existing_subnetwork_name used for GKE service alias IPs. Required when create_network = false. Ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.create_network || var.existing_services_range_name != null
    error_message = "existing_services_range_name is required when create_network = false."
  }
}

# ── Private Service Access ownership ──────────────────────────────────────────

variable "create_psa" {
  description = "When true (the default), the module allocates and manages the Private Service Access range and service networking connection used by Cloud SQL and Memorystore. Set to false when the network already has a Private Service Access connection the module should not manage; existing_psa_prerequisites_attestation must then be true if any module-managed data service is created."
  type        = bool
  default     = true
  nullable    = false
}

# This attestation is only ever consumed by its own validation block below;
# tflint does not treat a variable's self-referential validation condition as
# a use.
# tflint-ignore: terraform_unused_declarations
variable "existing_psa_prerequisites_attestation" {
  description = "Explicit attestation that an existing Private Service Access allocation and service networking connection already exist on the target network and are compatible with a module-managed Cloud SQL or Memorystore instance. Required (must be true) when create_psa = false and either create_postgres_instance or create_redis_instance is true. The module does not read or verify the existing connection; it only trusts this attestation and never mutates or deletes it."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = var.create_psa || !(var.create_postgres_instance || var.create_redis_instance) || var.existing_psa_prerequisites_attestation
    error_message = "existing_psa_prerequisites_attestation must be true when create_psa = false and the module creates Cloud SQL or Memorystore (create_postgres_instance or create_redis_instance), confirming a compatible Private Service Access connection already exists."
  }
}

# ── Networking (VPC-native) ────────────────────────────────────────────────────

variable "subnet_cidr" {
  description = "Primary CIDR for the node subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for GKE pods (VPC-native / alias IPs)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for GKE services (VPC-native / alias IPs)."
  type        = string
  default     = "10.30.0.0/20"
}

variable "psa_prefix_length" {
  description = "Prefix length for the Private Services Access range that Cloud SQL / Memorystore peer into."
  type        = number
  default     = 16
}

variable "psa_connection_abandon_on_destroy" {
  description = "When true (the default), the module-managed Private Services Access connection is dropped from Terraform state on destroy (deletion_policy = ABANDON) instead of calling the servicenetworking delete API, which GCP refuses with 'Producer services ... are still using this connection' for minutes to days after Cloud SQL and Memorystore are gone. Set false to attempt the API delete instead; it may stall. Read docs/destroy-cleanup.md before changing this, and run terraform apply once after changing it so the policy is recorded in state before the next destroy. Ignored when create_psa = false."
  type        = bool
  default     = true
  nullable    = false
}

# ── Cloud SQL ─────────────────────────────────────────────────────────────────

variable "postgres_version" {
  description = "Cloud SQL Postgres version."
  type        = string
  default     = "POSTGRES_16"
}

variable "postgres_edition" {
  description = "Cloud SQL edition. ENTERPRISE supports shared-core/legacy tiers like db-g1-small (cheap, dev). ENTERPRISE_PLUS requires db-perf-optimized-N-* tiers. Pinned because some projects/orgs default new instances to ENTERPRISE_PLUS, which rejects db-g1-small."
  type        = string
  default     = "ENTERPRISE"

  validation {
    condition     = contains(["ENTERPRISE", "ENTERPRISE_PLUS"], var.postgres_edition)
    error_message = "postgres_edition must be ENTERPRISE or ENTERPRISE_PLUS."
  }
}

variable "postgres_machine_type" {
  description = "Cloud SQL machine tier. ENTERPRISE: e.g. db-g1-small, db-custom-2-7680. ENTERPRISE_PLUS: e.g. db-perf-optimized-N-2. Must be compatible with postgres_edition."
  type        = string
  default     = "db-g1-small"
}

variable "postgres_availability_type" {
  description = "REGIONAL for HA (failover replica), ZONAL for single-zone."
  type        = string
  default     = "REGIONAL"
}

variable "postgres_disk_size" {
  description = "Cloud SQL data disk size in GB."
  type        = number
  default     = 50
}

variable "postgres_deletion_protection" {
  description = "Block terraform destroy of the Cloud SQL instance."
  type        = bool
  default     = true
}

# ── Cloud SQL backup and query-logging tuning (managed instance only) ────────
# Google Cloud Storage semantics (a retained backup COUNT and a
# transaction-log retention window), not AWS's retention-days model. Backups
# and point-in-time recovery stay enabled unconditionally (see the
# backup_configuration block in cloudsql.tf); these only tune how much history
# is kept. Ignored (and warned) for external PostgreSQL; see the
# postgres_tuning_ignored_when_external check in checks.tf.

variable "postgres_backup_retained_backups" {
  description = "Number of automated backups Cloud SQL retains (settings.backup_configuration.backup_retention_settings.retained_backups, retention_unit=COUNT). Null (the default) preserves the provider's existing default retention. Ignored when create_postgres_instance = false."
  type        = number
  default     = null

  validation {
    condition     = var.postgres_backup_retained_backups == null ? true : (var.postgres_backup_retained_backups >= 1 && var.postgres_backup_retained_backups <= 365 && floor(var.postgres_backup_retained_backups) == var.postgres_backup_retained_backups)
    error_message = "postgres_backup_retained_backups must be a whole number from 1 to 365, or null to keep the provider's default retention."
  }
}

variable "postgres_transaction_log_retention_days" {
  description = "Days of transaction logs Cloud SQL retains for point-in-time recovery (settings.backup_configuration.transaction_log_retention_days). Null (the default) preserves the provider's existing default. Valid range depends on postgres_edition: 1-7 for ENTERPRISE, 1-35 for ENTERPRISE_PLUS. Ignored when create_postgres_instance = false."
  type        = number
  default     = null

  validation {
    condition     = var.postgres_transaction_log_retention_days == null ? true : floor(var.postgres_transaction_log_retention_days) == var.postgres_transaction_log_retention_days
    error_message = "postgres_transaction_log_retention_days must be a whole number, or null to keep the provider's default retention."
  }

  validation {
    condition = var.postgres_transaction_log_retention_days == null ? true : (
      var.postgres_edition == "ENTERPRISE_PLUS" ? (var.postgres_transaction_log_retention_days >= 1 && var.postgres_transaction_log_retention_days <= 35) : (var.postgres_transaction_log_retention_days >= 1 && var.postgres_transaction_log_retention_days <= 7)
    )
    error_message = "postgres_transaction_log_retention_days must be 1-7 for ENTERPRISE, or 1-35 for ENTERPRISE_PLUS (postgres_edition)."
  }
}

variable "postgres_query_logging_enabled" {
  description = "When true, adds PostgreSQL database_flags to log DDL statements (log_statement=ddl) and statements taking at least 1000 ms (log_min_duration_statement=1000). Defaults to false (Query Insights' aggregate statistics remain enabled either way; this is unrelated all-statement text logging). Logged slow-statement text may include literal query parameter values; review your organization's data-handling policy before enabling. Ignored when create_postgres_instance = false."
  type        = bool
  default     = false
  nullable    = false
}

variable "n8n_database_name" {
  description = "n8n database name."
  type        = string
  default     = "n8n_enterprise"
}

variable "n8n_database_user" {
  description = "n8n database user."
  type        = string
  default     = "n8n"
}

# ── Cloud SQL restore source (managed instance only) ──────────────────────────
# Provider-supported backup restore or clone context for a NEW module-managed
# Cloud SQL instance (D4). Both mechanisms only apply at instance creation;
# neither retroactively restores/clones an already-created instance. Mutually
# exclusive with each other and meaningless when create_postgres_instance =
# false (see the postgres_restore_ignored_when_external check in checks.tf).
# Restoring/cloning does not carry over the n8n encryption key: see the
# postgres_restore_without_encryption_key_continuity check in checks.tf.

variable "postgres_clone_source_instance_name" {
  description = "Name of an existing Cloud SQL instance to clone from when creating the module-managed instance (the resource's clone block). Mutually exclusive with postgres_restore_backup_run_id. Ignored when create_postgres_instance = false. Only takes effect the first time the instance is created; it has no effect on an already-created instance."
  type        = string
  default     = null

  validation {
    condition     = var.postgres_clone_source_instance_name == null || var.postgres_restore_backup_run_id == null
    error_message = "postgres_clone_source_instance_name and postgres_restore_backup_run_id are mutually exclusive; use exactly one restore mechanism."
  }

  validation {
    condition     = var.create_postgres_instance || var.postgres_clone_source_instance_name == null
    error_message = "postgres_clone_source_instance_name requires create_postgres_instance = true; cloning only applies to a module-managed instance."
  }
}

variable "postgres_clone_point_in_time" {
  description = "RFC3339 timestamp to clone postgres_clone_source_instance_name from a specific point in time (requires point-in-time recovery enabled on the source). Requires postgres_clone_source_instance_name when set."
  type        = string
  default     = null

  validation {
    condition     = var.postgres_clone_point_in_time == null || var.postgres_clone_source_instance_name != null
    error_message = "postgres_clone_point_in_time requires postgres_clone_source_instance_name; a point in time without a clone source would be ignored."
  }
}

variable "postgres_restore_backup_run_id" {
  description = "Backup run ID to restore into the module-managed Cloud SQL instance at creation (the resource's restore_backup_context block). Requires postgres_restore_source_instance_name. Mutually exclusive with postgres_clone_source_instance_name. Ignored when create_postgres_instance = false."
  type        = number
  default     = null

  validation {
    condition     = var.create_postgres_instance || var.postgres_restore_backup_run_id == null
    error_message = "postgres_restore_backup_run_id requires create_postgres_instance = true; restoring only applies to a module-managed instance."
  }
}

variable "postgres_restore_source_instance_name" {
  description = "Name of the Cloud SQL instance that owns the backup named by postgres_restore_backup_run_id. Must be set together with postgres_restore_backup_run_id."
  type        = string
  default     = null

  validation {
    condition     = (var.postgres_restore_backup_run_id == null) == (var.postgres_restore_source_instance_name == null)
    error_message = "postgres_restore_backup_run_id and postgres_restore_source_instance_name must be set together."
  }
}

# ── Cloud SQL customer-managed encryption (Cloud KMS) ─────────────────────────
# Explicit create-or-reference contract (D4): create_postgres_kms_key creates a
# key in the shared key ring (create_kms_key_ring / existing_kms_key_ring_id,
# below), existing_postgres_kms_key_id references an already-existing key, and
# leaving both unset keeps Google-managed encryption. The module never mutates
# encryption on an external database (create_postgres_instance = false).

variable "create_postgres_kms_key" {
  description = "When true, the module creates a Cloud KMS CryptoKey in the shared key ring (see create_kms_key_ring/existing_kms_key_ring_id) and configures the module-managed Cloud SQL instance to use it as its customer-managed encryption key. Mutually exclusive with existing_postgres_kms_key_id. Ignored when create_postgres_instance = false. Defaults to false (Google-managed encryption). The created key is protected by lifecycle prevent_destroy; see docs/destroy-cleanup.md for how to back out of a module-created key."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.create_postgres_kms_key || var.existing_postgres_kms_key_id == null
    error_message = "create_postgres_kms_key and existing_postgres_kms_key_id are mutually exclusive; create a key or reference an existing one, not both."
  }
}

variable "existing_postgres_kms_key_id" {
  description = "Fully qualified ID (projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>) of an existing Cloud KMS key the module-managed Cloud SQL instance should use for customer-managed encryption. Mutually exclusive with create_postgres_kms_key. The module grants no IAM on a supplied existing key; grant the Cloud SQL service agent roles/cloudkms.cryptoKeyEncrypterDecrypter on it out of band. Ignored when create_postgres_instance = false."
  type        = string
  default     = null
}

# ── Shared Cloud KMS key ring ──────────────────────────────────────────────────
# A single optional key ring hosts every module-created CMEK key (Cloud SQL
# today; Memorystore and GCS extend this same ring in later sections). Its
# creation is independent of any individual service's key-creation switch: it
# is required only when at least one service opts into a module-created key.

variable "create_kms_key_ring" {
  description = "When true, the module creates and manages a Cloud KMS key ring to host module-created CMEK keys (create_postgres_kms_key, create_redis_kms_key, create_gcs_kms_key, create_gke_kms_key). Ignored unless at least one service's create_*_kms_key switch is true. Set to false and supply existing_kms_key_ring_id to host module-created keys in an existing key ring instead. Defaults to false."
  type        = bool
  default     = false
  nullable    = false
}

variable "existing_kms_key_ring_id" {
  description = "Fully qualified ID (projects/<project>/locations/<location>/keyRings/<ring>) of an existing Cloud KMS key ring to host module-created CMEK keys. Required when create_kms_key_ring = false and at least one service's create_*_kms_key switch is true. Ignored when create_kms_key_ring = true or no module-created key is requested."
  type        = string
  default     = null

  validation {
    condition = var.create_kms_key_ring || !(
      (var.create_postgres_instance && var.create_postgres_kms_key) ||
      (var.create_redis_instance && var.create_redis_kms_key) ||
      (var.create_gcs_bucket && var.create_gcs_kms_key) ||
      (var.create_gke && var.create_gke_kms_key)
    ) || var.existing_kms_key_ring_id != null
    error_message = "existing_kms_key_ring_id is required when create_kms_key_ring = false and create_postgres_kms_key, create_redis_kms_key, create_gcs_kms_key, or create_gke_kms_key is true."
  }

  validation {
    condition = var.existing_kms_key_ring_id == null || can(regex(
      "^projects/[^/]+/locations/[^/]+/keyRings/[^/]+$",
      var.existing_kms_key_ring_id,
    ))
    error_message = "existing_kms_key_ring_id must be a fully qualified key-ring ID: projects/<project>/locations/<location>/keyRings/<ring>."
  }

  validation {
    condition = var.existing_kms_key_ring_id == null ? true : (
      (!(var.create_postgres_instance && var.create_postgres_kms_key) && !(var.create_redis_instance && var.create_redis_kms_key) && !(var.create_gke && var.create_gke_kms_key)) || try(lower(split("/", var.existing_kms_key_ring_id)[3]), "") == lower(var.gcp_region)
      ) && (
      !(var.create_gcs_bucket && var.create_gcs_kms_key) || try(lower(split("/", var.existing_kms_key_ring_id)[3]), "") == (lower(var.gcs_location) == "eu" ? "europe" : lower(var.gcs_location))
    )
    error_message = "The existing key ring location must match every service using a module-created key: gcp_region for Cloud SQL/Redis/GKE, and the GCS-compatible location (EU maps to europe) for GCS. A single ring cannot serve incompatible locations."
  }
}

variable "kms_key_ring_location" {
  description = "Location for the module-managed Cloud KMS key ring. Defaults to gcp_region for Cloud SQL/Redis/GKE keys, or to the GCS-compatible bucket location for a GCS-only ring (EU maps to europe). Every service sharing the ring must support the same location."
  type        = string
  default     = null

  validation {
    condition = !var.create_kms_key_ring || (
      (!(var.create_postgres_instance && var.create_postgres_kms_key) && !(var.create_redis_instance && var.create_redis_kms_key) && !(var.create_gke && var.create_gke_kms_key)) || (var.kms_key_ring_location == null ? true : lower(var.kms_key_ring_location) == lower(var.gcp_region))
      ) && (
      !(var.create_gcs_bucket && var.create_gcs_kms_key) || (var.kms_key_ring_location == null ? true : lower(var.kms_key_ring_location) == (lower(var.gcs_location) == "eu" ? "europe" : lower(var.gcs_location)))
      ) && (
      !((var.create_postgres_instance && var.create_postgres_kms_key) || (var.create_redis_instance && var.create_redis_kms_key) || (var.create_gke && var.create_gke_kms_key)) ||
      !(var.create_gcs_bucket && var.create_gcs_kms_key) ||
      lower(var.gcp_region) == (lower(var.gcs_location) == "eu" ? "europe" : lower(var.gcs_location))
    )
    error_message = "kms_key_ring_location must match every service using the shared ring: gcp_region for Cloud SQL/Redis/GKE, and the GCS-compatible location (EU maps to europe) for GCS. A single ring cannot serve incompatible locations."
  }
}

variable "create_redis_instance" {
  description = "When true (the default), the module creates and manages a Memorystore for Redis instance. Set to false to use an external Redis-compatible service; redis_host must then be supplied (redis_port, redis_tls_enabled, redis_username, and a password source are optional depending on the target service)."
  type        = bool
  default     = true
  nullable    = false
}

variable "redis_host" {
  description = "External Redis host. Required when create_redis_instance = false. Ignored otherwise (n8n and KEDA use the module-managed Memorystore host)."
  type        = string
  default     = null

  validation {
    condition     = var.create_redis_instance || var.redis_host != null
    error_message = "redis_host is required when create_redis_instance = false."
  }
}

variable "redis_port" {
  description = "External Redis port. Ignored when create_redis_instance = true (Memorystore always uses 6379)."
  type        = number
  default     = 6379

  validation {
    condition     = var.redis_port > 0 && var.redis_port <= 65535
    error_message = "redis_port must be a valid TCP port (1-65535)."
  }
}

variable "redis_tls_enabled" {
  description = "Whether n8n and KEDA connect to the external Redis host over TLS. Ignored when create_redis_instance = true (managed Memorystore transit encryption is controlled separately)."
  type        = bool
  default     = false
  nullable    = false
}

variable "redis_username" {
  description = "Optional ACL username for the external Redis host (Redis 6+ ACL-compatible services). Ignored when create_redis_instance = true. Passed to n8n as a plain chart value and wrapped in a module-managed Secret purely so KEDA's TriggerAuthentication can reference it too."
  type        = string
  default     = null
}

variable "redis_password" {
  description = "Optional direct password for the external Redis host. Mutually exclusive with redis_password_secret_ref. Ignored when create_redis_instance = true (the module manages Memorystore AUTH via redis_auth_enabled instead)."
  type        = string
  default     = null
  sensitive   = true
}

# The completeness/mutual-exclusivity condition below references both this
# variable and redis_password, so it lives on exactly one of the two (here)
# rather than being duplicated on both: a validation block on each variable
# referencing the other would form a validation-graph cycle (see
# n8n_database_password_secret_ref for the same pattern).
variable "redis_password_secret_ref" {
  description = "Reference to an existing Kubernetes Secret (in the n8n namespace) holding the external Redis password, instead of passing the value directly through redis_password. key defaults to \"password\" when omitted. The module never reads the referenced Secret's value; it only passes the reference through to the n8n Helm chart's redis.passwordSecret and to KEDA's TriggerAuthentication. Mutually exclusive with redis_password. Both are optional (unlike PostgreSQL, external Redis may run without a password). Ignored when create_redis_instance = true."
  type = object({
    name = string
    key  = optional(string, "password")
  })
  default = null

  validation {
    condition     = var.redis_password == null || var.redis_password_secret_ref == null
    error_message = "redis_password and redis_password_secret_ref are mutually exclusive; supply the external Redis password directly or via an existing Secret reference, not both."
  }
}

variable "redis_key_prefix" {
  description = "Optional prefix n8n applies to both its command channel (N8N_REDIS_KEY_PREFIX, n8n default \"n8n\") and its Bull queue Redis keys (the chart's redis.prefix, chart default \"bull\"), synchronized with the corresponding KEDA queue list names (\"<prefix>:jobs:wait\" / \"<prefix>:jobs:active\") and, when enabled, the Redis exporter's queue-key checks. Leave null (the default) to use n8n's and the chart's own distinct default prefixes. Changing this value on a deployment with in-flight or queued jobs strands them under the old prefix; drain the queue first (see docs/customer-managed-infrastructure.md)."
  type        = string
  default     = null

  validation {
    condition     = var.redis_key_prefix == null || can(regex("^[A-Za-z0-9_-]+$", var.redis_key_prefix))
    error_message = "redis_key_prefix must be null or a non-blank value containing only letters, digits, hyphens, and underscores; whitespace and colons (the Bull key separator) would produce a malformed key."
  }
}

variable "n8n_redis_timeout_threshold_ms" {
  description = "Milliseconds n8n waits for a Redis response before treating the connection as failed (the chart's redis.timeout / QUEUE_BULL_REDIS_TIMEOUT_THRESHOLD). Must be at least 30000 when redis_tier = STANDARD_HA on a module-managed instance, covering Memorystore's documented ~30s average unavailability during an automated failover."
  type        = number
  default     = 10000
  nullable    = false

  validation {
    condition     = !(var.create_redis_instance && var.redis_tier == "STANDARD_HA") || var.n8n_redis_timeout_threshold_ms >= 30000
    error_message = "n8n_redis_timeout_threshold_ms must be at least 30000 (30s) when redis_tier = STANDARD_HA, matching Memorystore's documented average failover unavailability window; a lower value risks n8n exiting mid-failover."
  }
}

variable "n8n_queue_worker_lock_duration" {
  description = "Milliseconds a worker holds an execution lease before it is considered stalled and eligible for another worker to pick up (the chart's redis.worker.lockDuration). Null (the default) omits the override so the chart's own default (60000) applies. Wired alongside n8n_queue_worker_lock_renew_time and n8n_queue_worker_stalled_interval into one nested redis.worker chart map so partial overrides do not discard the others' values."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_queue_worker_lock_duration == null ? true : (var.n8n_queue_worker_lock_duration >= 1000 && floor(var.n8n_queue_worker_lock_duration) == var.n8n_queue_worker_lock_duration)
    error_message = "n8n_queue_worker_lock_duration must be a whole number of milliseconds of at least 1000, or null to omit the override."
  }
}

variable "n8n_queue_worker_lock_renew_time" {
  description = "Milliseconds between a worker's automatic renewals of its execution lease (the chart's redis.worker.lockRenewTime). Null (the default) omits the override so the chart's own default (10000) applies. Must resolve to strictly less than the effective lock duration (this input, or the chart's 60000 default when n8n_queue_worker_lock_duration is also null); otherwise the lease would expire before a renewal could ever land."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_queue_worker_lock_renew_time == null ? true : (var.n8n_queue_worker_lock_renew_time >= 1000 && floor(var.n8n_queue_worker_lock_renew_time) == var.n8n_queue_worker_lock_renew_time)
    error_message = "n8n_queue_worker_lock_renew_time must be a whole number of milliseconds of at least 1000, or null to omit the override."
  }

  validation {
    condition     = coalesce(var.n8n_queue_worker_lock_renew_time, 10000) < coalesce(var.n8n_queue_worker_lock_duration, 60000)
    error_message = "n8n_queue_worker_lock_renew_time must resolve to strictly less than the effective n8n_queue_worker_lock_duration (falling back to the chart's 10000/60000 defaults for whichever is null); otherwise the lease can expire before a renewal lands."
  }
}

variable "n8n_queue_worker_stalled_interval" {
  description = "Milliseconds between checks for stalled jobs (jobs whose lease expired without renewal) (the chart's redis.worker.stalledInterval). Null (the default) omits the override so the chart's own default (30000) applies."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_queue_worker_stalled_interval == null ? true : (var.n8n_queue_worker_stalled_interval >= 1000 && floor(var.n8n_queue_worker_stalled_interval) == var.n8n_queue_worker_stalled_interval)
    error_message = "n8n_queue_worker_stalled_interval must be a whole number of milliseconds of at least 1000, or null to omit the override; the pinned chart schema also forbids a stalled interval below 1000."
  }
}

variable "n8n_graceful_shutdown_timeout" {
  description = "Seconds n8n gives in-flight executions to finish after it receives SIGTERM, before it exits on its own (the chart's redis.worker.timeout, N8N_GRACEFUL_SHUTDOWN_TIMEOUT on every n8n container). Null (the default) omits the override so the chart's own default (30s) applies. Set it here, not through n8n_extra_env, n8n_worker_extra_env, or an n8n_worker_pools entry's extra_env, which all reject this name at plan time: unlike n8n_queue_worker_lock_duration, n8n_queue_worker_lock_renew_time, and n8n_queue_worker_stalled_interval, the chart renders its own entry for this key unconditionally, and Kubernetes silently keeps the last of two same-named entries, so a caller duplicate would replace the chart's value with no warning. n8n_termination_grace_period is a hard ceiling: Kubernetes starts that countdown when termination begins, the preStop hook (n8n_prestop_sleep) runs inside it, and SIGTERM follows the hook. So this value plus n8n_prestop_sleep must stay strictly below n8n_termination_grace_period, or SIGKILL cuts n8n's shutdown short. An explicit value that breaks this rule fails validation. When this input is null, the same rule applied to the chart's default only raises a warning (the graceful_shutdown_fits_grace_period check), so existing configurations keep planning. That warning is skipped for a custom n8n_chart_repository, whose default the module cannot verify."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_graceful_shutdown_timeout == null ? true : (var.n8n_graceful_shutdown_timeout >= 1 && floor(var.n8n_graceful_shutdown_timeout) == var.n8n_graceful_shutdown_timeout)
    error_message = "n8n_graceful_shutdown_timeout must be a whole number of seconds of at least 1, or null to omit the override; the pinned chart schema declares redis.worker.timeout as an integer with a minimum of 1."
  }

  # Only an explicit value is a hard error. The same rule for the chart's
  # default (null here) is a warning, check.graceful_shutdown_fits_grace_period
  # in checks.tf: callers who never set this input could already plan with a
  # preStop sleep that leaves less than 30 seconds, and a new plan-time error
  # would break them on upgrade.
  validation {
    condition     = var.n8n_graceful_shutdown_timeout == null ? true : (var.n8n_graceful_shutdown_timeout + var.n8n_prestop_sleep < var.n8n_termination_grace_period)
    error_message = "n8n_graceful_shutdown_timeout plus n8n_prestop_sleep must stay strictly below n8n_termination_grace_period. Kubernetes starts the terminationGracePeriodSeconds countdown when it invokes preStop, not after preStop finishes, so a sum equal to or above the ceiling leaves n8n's own shutdown no margin before SIGKILL. Lower this value or n8n_prestop_sleep, or raise n8n_termination_grace_period."
  }
}

# ── Memorystore ───────────────────────────────────────────────────────────────

variable "redis_tier" {
  description = "Memorystore tier: BASIC (no replica) or STANDARD_HA (adds a replica and automated failover)."
  type        = string
  default     = "BASIC"

  validation {
    condition     = contains(["BASIC", "STANDARD_HA"], var.redis_tier)
    error_message = "redis_tier must be BASIC or STANDARD_HA."
  }
}

variable "redis_memory_size_gb" {
  description = "Memorystore capacity in GB."
  type        = number
  default     = 1
}

variable "redis_version" {
  description = "Memorystore Redis version."
  type        = string
  default     = "REDIS_7_2"
}

variable "redis_auth_enabled" {
  description = "Enable Redis AUTH on the module-managed Memorystore instance. If true, the KEDA worker trigger gets a TriggerAuthentication CRD referencing the generated AUTH string."
  type        = bool
  default     = false
}

variable "redis_transit_encryption_enabled" {
  description = "Enable in-transit (TLS) encryption on the module-managed Memorystore instance (transit_encryption_mode = SERVER_AUTHENTICATION). n8n and KEDA connect over TLS when set. Ignored when create_redis_instance = false; use redis_tls_enabled for an external Redis host instead."
  type        = bool
  default     = false
  nullable    = false
}

# ── Opt-in Memorystore RDB persistence (managed instance only) ───────────────
# Memorystore's own automatic last-snapshot recovery (persistence_config),
# not AWS ElastiCache's numbered snapshot-retention count: enabling this keeps
# at most one RDB snapshot that Memorystore replays on an unplanned restart,
# not a history of restore points. Disabled by default; see docs guidance
# before enabling on a memory- or latency-sensitive workload. Ignored (and
# warned) for external Redis; see the redis_tuning_ignored_when_existing and
# redis_persistence_tuning_ignored_when_disabled checks in checks.tf.

variable "redis_persistence_enabled" {
  description = "When true, enables Memorystore RDB persistence (persistence_config.persistence_mode = RDB) on the module-managed instance, keeping one automatically-replayed snapshot for unplanned restarts. This is NOT a historical backup or a substitute for a separate export; see redis_rdb_snapshot_period/redis_rdb_snapshot_start_time and docs/post-deployment.md for recovery, memory, and latency guidance. Ignored when create_redis_instance = false. Defaults to false."
  type        = bool
  default     = false
  nullable    = false
}

variable "redis_rdb_snapshot_period" {
  description = "Memorystore RDB snapshot schedule period (persistence_config.rdb_snapshot_period). One of ONE_HOUR, SIX_HOURS, TWELVE_HOURS, or TWENTY_FOUR_HOURS. Ignored when redis_persistence_enabled = false or create_redis_instance = false. Defaults to TWENTY_FOUR_HOURS."
  type        = string
  default     = "TWENTY_FOUR_HOURS"
  nullable    = false

  validation {
    condition     = contains(["ONE_HOUR", "SIX_HOURS", "TWELVE_HOURS", "TWENTY_FOUR_HOURS"], var.redis_rdb_snapshot_period)
    error_message = "redis_rdb_snapshot_period must be one of ONE_HOUR, SIX_HOURS, TWELVE_HOURS, or TWENTY_FOUR_HOURS."
  }
}

variable "redis_rdb_snapshot_start_time" {
  description = "RFC3339 UTC timestamp (e.g. \"2024-01-01T03:00:00Z\") that the first RDB snapshot was/will be attempted, and to which future snapshots align (persistence_config.rdb_snapshot_start_time). Null (the default) lets Memorystore use the current time. Ignored when redis_persistence_enabled = false or create_redis_instance = false."
  type        = string
  default     = null

  validation {
    condition     = var.redis_rdb_snapshot_start_time == null || can(formatdate("YYYY", var.redis_rdb_snapshot_start_time))
    error_message = "redis_rdb_snapshot_start_time must be null or a valid RFC3339 UTC timestamp (e.g. \"2024-01-01T03:00:00Z\")."
  }
}

# ── Opt-in Redis exporter (observability.tf) ───────────────────────────────────
# Independent of n8n_metrics_enabled, KEDA installation, and scaler ownership;
# see locals.tf's effective_redis_* / effective_redis_queue_keys, which the
# exporter shares with n8n and KEDA so all three consumers watch the same
# connection and queue keys.

variable "redis_exporter_enabled" {
  description = "When true, creates a single-replica Redis exporter Deployment and a ClusterIP metrics Service (port 9121) that reads Bull queue depth and other metrics from the effective Redis connection (module-managed Memorystore or external). Independent of n8n_metrics_enabled and worker KEDA. Installs no Prometheus or Grafana resources; pair with a cluster Prometheus that discovers pods by the scrape annotations this module sets, or a ServiceMonitor pointed at redis_exporter_service_name. Defaults to false."
  type        = bool
  default     = false
  nullable    = false
}

variable "redis_exporter_image" {
  description = "Container image (repository:tag[@digest]) for the Redis exporter. Defaults to the pinned, verified \"oliver006/redis_exporter:v1.90.0\", pinned by digest (sha256:a129504e...) as well as tag: the tag alone is mutable, so the default IfNotPresent pull policy could otherwise keep running a superseded image once the tag moves. Must include an explicit tag; an unpinned floating tag is not accepted. An optional trailing @sha256:<64-hex> digest is accepted on any image, including a caller-supplied one. Ignored when redis_exporter_enabled = false. A custom image runs as the module-set UID 59000, matching the default image's own non-root user."
  type        = string
  default     = "oliver006/redis_exporter:v1.90.0@sha256:a129504e65b87c54f79bc92f1afc403475e8ff646a3d7512de469904ceddf986"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]+((\\.|_|__|-+)[a-z0-9]+)*(/[a-z0-9]+((\\.|_|__|-+)[a-z0-9]+)*)*:[A-Za-z0-9_][A-Za-z0-9._-]*(@sha256:[A-Fa-f0-9]{64})?$", var.redis_exporter_image))
    error_message = "redis_exporter_image must be a bare image reference including an explicit tag (e.g. \"oliver006/redis_exporter:v1.90.0\"), optionally followed by \"@sha256:<64 hex characters>\": lowercase path components, no scheme, no whitespace, and a tag after the final colon before any digest."
  }
}

# ── Memorystore customer-managed encryption (Cloud KMS) ───────────────────────
# Same explicit create-or-reference contract as Cloud SQL (D4): create_redis_kms_key
# creates a key in the shared ring (create_kms_key_ring/existing_kms_key_ring_id),
# existing_redis_kms_key_id references an already-existing key, and leaving both
# unset keeps Google-managed encryption. Memorystore does not support enabling
# CMEK on an already-created instance, so this only takes effect at creation.
# Ignored when create_redis_instance = false.

variable "create_redis_kms_key" {
  description = "When true, the module creates a Cloud KMS CryptoKey in the shared key ring (see create_kms_key_ring/existing_kms_key_ring_id) and configures the module-managed Memorystore instance to use it as its customer-managed encryption key. Mutually exclusive with existing_redis_kms_key_id. Ignored when create_redis_instance = false. Defaults to false (Google-managed encryption). The created key is protected by lifecycle prevent_destroy; see docs/destroy-cleanup.md for how to back out of a module-created key."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.create_redis_kms_key || var.existing_redis_kms_key_id == null
    error_message = "create_redis_kms_key and existing_redis_kms_key_id are mutually exclusive; create a key or reference an existing one, not both."
  }
}

variable "existing_redis_kms_key_id" {
  description = "Fully qualified ID (projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>) of an existing Cloud KMS key the module-managed Memorystore instance should use for customer-managed encryption. Mutually exclusive with create_redis_kms_key. The module grants no IAM on a supplied existing key; grant the Memorystore service agent roles/cloudkms.cryptoKeyEncrypterDecrypter on it out of band. Ignored when create_redis_instance = false."
  type        = string
  default     = null
}

# ── GCS bucket ownership ──────────────────────────────────────────────────────

variable "create_gcs_bucket" {
  description = "When true (the default), the module creates and manages the GCS bucket used for n8n binary storage. Set to false to use an existing bucket; existing_gcs_bucket_name must then be supplied. HMAC identity ownership (gcs_hmac_service_account_email) is independent of bucket ownership: the module still grants bucket-scoped IAM to the effective HMAC identity."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_gcs_bucket_name" {
  description = "Name of the existing GCS bucket used for n8n binary storage. Required when create_gcs_bucket = false. Ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.create_gcs_bucket || var.existing_gcs_bucket_name != null
    error_message = "existing_gcs_bucket_name is required when create_gcs_bucket = false."
  }
}

# ── GCS customer-managed encryption (Cloud KMS) ───────────────────────────────
# Same explicit create-or-reference contract as Cloud SQL and Memorystore (D4):
# create_gcs_kms_key creates a key in the shared ring (create_kms_key_ring/
# existing_kms_key_ring_id), existing_gcs_kms_key_id references an
# already-existing key, and leaving both unset keeps Google-managed
# encryption. Only takes effect for a module-managed bucket at creation;
# ignored (and never mutates) an existing bucket. Ignored when
# create_gcs_bucket = false.

variable "create_gcs_kms_key" {
  description = "When true, the module creates a Cloud KMS CryptoKey in the shared key ring (see create_kms_key_ring/existing_kms_key_ring_id) and configures the module-managed GCS bucket to use it as its default customer-managed encryption key. Mutually exclusive with existing_gcs_kms_key_id. Ignored when create_gcs_bucket = false. Defaults to false (Google-managed encryption). The created key is protected by lifecycle prevent_destroy; see docs/destroy-cleanup.md for how to back out of a module-created key."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.create_gcs_kms_key || var.existing_gcs_kms_key_id == null
    error_message = "create_gcs_kms_key and existing_gcs_kms_key_id are mutually exclusive; create a key or reference an existing one, not both."
  }
}

variable "existing_gcs_kms_key_id" {
  description = "Fully qualified ID (projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>) of an existing Cloud KMS key the module-managed GCS bucket should use for customer-managed encryption. Mutually exclusive with create_gcs_kms_key. The module grants no IAM on a supplied existing key; grant the Cloud Storage service agent roles/cloudkms.cryptoKeyEncrypterDecrypter on it out of band. Ignored when create_gcs_bucket = false."
  type        = string
  default     = null
}

# ── GCS binary storage ────────────────────────────────────────────────────────

variable "gcs_location" {
  description = "GCS bucket location (region or multi-region)."
  type        = string
  default     = "EU"
}

variable "gcs_force_destroy" {
  description = "Allow terraform destroy to delete a non-empty bucket (dev only)."
  type        = bool
  default     = false
}

variable "manage_sa_key_org_policy" {
  description = <<-EOT
    Opt-in: let this module set a PROJECT-LEVEL override that turns OFF the
    iam.disableServiceAccountKeyCreation org policy, so the GCS HMAC key can be
    created. Default false, the module does not touch org policy.
    Set true ONLY IF: (a) your credentials have roles/orgpolicy.policyAdmin (org/
    folder-level; a normal project deployer does not), and (b) your org permits
    overriding this guardrail. Otherwise disable the policy out-of-band and leave
    this false. Requires the orgpolicy.googleapis.com API enabled.
  EOT
  type        = bool
  default     = false
}

# ── BYO / pre-existing HMAC key ───────────────────────────────────────────────
# For orgs that cannot relax iam.disableServiceAccountKeyCreation at all: create
# the service account + HMAC key out of band and pass them in here, so the module
# never calls google_storage_hmac_key. Leave these empty for the default path
# (module creates the SA and key itself). When set, the module grants the
# supplied service account access to the module-created bucket.

variable "gcs_hmac_service_account_email" {
  description = <<-EOT
    BYO HMAC mode: email of a PRE-EXISTING service account that owns an
    out-of-band-created HMAC key. When set, the module does NOT create the storage
    service account or the HMAC key; it grants this SA objectAdmin on the bucket
    and wires the credentials below into n8n. Requires gcs_hmac_access_id and
    either gcs_hmac_secret or gcs_hmac_secret_name. Empty = default (module
    creates the key).
  EOT
  type        = string
  default     = ""
}

variable "gcs_hmac_access_id" {
  description = "BYO HMAC mode: the HMAC access ID (S3 access key) for the pre-existing key. Required when gcs_hmac_service_account_email is set."
  type        = string
  default     = ""

  # Required in BYO mode (or n8n gets an empty S3 access key), meaningless
  # outside it (the module-created key supplies its own access ID).
  validation {
    condition     = (var.gcs_hmac_service_account_email == "") == (var.gcs_hmac_access_id == "")
    error_message = "gcs_hmac_access_id is required when gcs_hmac_service_account_email is set (BYO HMAC mode), and must be empty otherwise."
  }

  # BYO mode must also come with a usable secret; failing the plan here (not
  # at a check warning) prevents an apply that deploys n8n with broken S3
  # credentials. The rule keys off gcs_hmac_access_id (which the validation
  # above ties to BYO mode) rather than off gcs_hmac_service_account_email,
  # so the cross-variable validation references stay acyclic (the secret
  # inputs already reference the email) and the condition tests its own
  # variable as Terraform requires.
  validation {
    condition = var.gcs_hmac_access_id == "" || (
      var.gcs_hmac_secret != "" || var.gcs_hmac_secret_name != ""
    )
    error_message = "gcs_hmac_access_id is set (BYO HMAC mode), so either gcs_hmac_secret or gcs_hmac_secret_name is also required."
  }
}

variable "gcs_hmac_secret" {
  description = "BYO HMAC mode: the HMAC secret (S3 secret access key). The module wraps it in the n8n-s3-secret Kubernetes Secret. Ignored if gcs_hmac_secret_name is set. Prefer gcs_hmac_secret_name to keep the raw secret out of Terraform state."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.gcs_hmac_secret == "" || var.gcs_hmac_service_account_email != ""
    error_message = "gcs_hmac_secret is only used in BYO HMAC mode; set gcs_hmac_service_account_email as well, or leave gcs_hmac_secret empty (the module-created key supplies its own secret)."
  }
}

variable "gcs_hmac_secret_name" {
  description = "BYO HMAC mode (most locked-down): name of an EXISTING Kubernetes Secret in the n8n namespace holding the HMAC secret under key 'accessSecret'. When set, the module references it directly and creates no Secret, so the raw secret never enters Terraform state. Overrides gcs_hmac_secret."
  type        = string
  default     = ""

  # Outside BYO mode the module creates its own HMAC key, whose secret could
  # never match an externally supplied Secret; reject the combination.
  validation {
    condition     = var.gcs_hmac_secret_name == "" || var.gcs_hmac_service_account_email != ""
    error_message = "gcs_hmac_secret_name is only used in BYO HMAC mode; the module-created HMAC key's secret would not match an external Secret. Set gcs_hmac_service_account_email as well, or leave gcs_hmac_secret_name empty."
  }
}

# ── Workload Identity ─────────────────────────────────────────────────────────

variable "n8n_kube_svc_account" {
  description = "Kubernetes ServiceAccount the n8n pods run as (annotated for Workload Identity). Matches the n8n Helm chart's serviceAccount name."
  type        = string
  default     = "n8n"
}

# ── TLS ───────────────────────────────────────────────────────────────────────
# The native gce Ingress terminates TLS at the Google Cloud L7 LB, so the cert
# must be presentable to that LB. tls_mode selects how, using ONLY GCP-native or
# BYO mechanisms so the base module needs no third-party provider. Automated
# Let's Encrypt (which needs a DNS-01 solver) is delivered by examples/cloudflare,
# which populates a k8s TLS Secret and sets tls_mode = "secret".

variable "tls_mode" {
  description = <<-EOT
    How the LB gets its cert (base module, provider-clean):
      - "google_managed" : ManagedCertificate CRD, auto-renew. DEFAULT. Validated end to end; the DNS A-record must point at the LB static IP before the cert can provision.
      - "custom"         : bring your own PEM (tls_cert_pem/tls_key_pem), e.g. a Cloudflare Origin CA cert, uploaded as a pre-shared cert.
      - "secret"         : the gce Ingress consumes an existing k8s TLS Secret (tls_secret_name). This is how examples/cloudflare wires Let's Encrypt via cert-manager.
      - "self_signed"    : instant cert with a browser warning, for smoke tests before DNS is live.
  EOT
  type        = string
  default     = "google_managed"

  validation {
    condition     = contains(["google_managed", "custom", "secret", "self_signed"], var.tls_mode)
    error_message = "tls_mode must be one of: google_managed, custom, secret, self_signed."
  }
}

variable "tls_cert_pem" {
  description = "PEM certificate chain (tls_mode = custom), e.g. a Cloudflare Origin CA cert. Must cover every hostname in n8n_ingress_hosts (n8n_fqdn plus every n8n_additional_domains entry), e.g. via SANs or a wildcard; the module uploads this PEM as-is to google_compute_ssl_certificate and does not parse or validate its coverage."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_key_pem" {
  description = "PEM private key (tls_mode = custom)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_secret_name" {
  description = "Name of an existing Kubernetes TLS Secret the Ingress should use (tls_mode = secret). Populated by an external issuer such as cert-manager in examples/cloudflare. The referenced Secret's certificate must cover every hostname in n8n_ingress_hosts (n8n_fqdn plus every n8n_additional_domains entry); the module declares all of them on the Ingress's spec.tls.hosts but does not read the external Secret to confirm its certificate actually covers them."
  type        = string
  default     = "n8n-tls"
}

variable "https_redirect" {
  description = "Redirect HTTP->HTTPS at the LB via a FrontendConfig. Set false while a google_managed cert is still provisioning (Google needs HTTP reachable), then flip true."
  type        = bool
  default     = true
}

# ── DNS (Google Cloud DNS , base/default path) ────────────────────────────────
# The base module manages the record in Google Cloud DNS (the small/default
# example). Alternative DNS providers are examples that manage their own record
# against the module's static IP output (examples/cloudflare, examples/godaddy).

variable "cloud_dns_zone_name" {
  description = "Google Cloud DNS managed-zone name to create the A record in. Empty string means the module does not manage DNS (you point n8n_fqdn at the static IP output yourself, as examples/cloudflare does). This single zone must cover every hostname in n8n_ingress_hosts (n8n_fqdn plus every n8n_additional_domains entry); the module creates one A record per hostname in this zone and does not split records across zones. An alias whose DNS lives in a different zone or provider is the caller's responsibility to create against the static_ip output, the same way examples/cloudflare and examples/godaddy manage the canonical record."
  type        = string
  default     = ""
}

# ── Additional ingress hosts and annotations ───────────────────────────────
# Both are rendered into the module-managed Ingress (n8n.tf's
# kubernetes_ingress_v1.n8n) and its supporting DNS/certificate resources
# (dns.tf/crds.tf; task 20.2). n8n_ingress_hosts (outputs.tf) exposes the
# effective host list unconditionally, so a customer-managed ingress can
# route the same hostnames the module would.

variable "n8n_additional_domains" {
  description = "Additional hostnames to give the full main/webhook route set alongside n8n_fqdn, e.g. for a second public domain pointed at the same deployment. Compared case-insensitively everywhere the module uses them (duplicate detection, Cloud DNS records, ManagedCertificate/self-signed/Secret TLS coverage); see n8n_ingress_hosts for the effective lowercase-normalized list. Wildcards are not accepted. Adds no DNS, certificate, or ingress resource when create_ingress = false, but n8n_ingress_hosts still reports these hostnames for a caller-managed ingress to route."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for d in var.n8n_additional_domains : can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", d))
    ])
    error_message = "Every n8n_additional_domains entry must be a valid fully qualified domain name (e.g. alt.example.com); wildcards (e.g. *.example.com) are not accepted."
  }

  validation {
    condition = alltrue([
      for d in var.n8n_additional_domains : alltrue([
        for label in split(".", d) :
        length(label) >= 1 && length(label) <= 63 && can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", label))
      ])
    ])
    error_message = "Every dot-separated label of each n8n_additional_domains entry must be 1 to 63 characters, start and end with an alphanumeric character, and contain only alphanumerics and hyphens (the DNS-1123 label rule GKE Ingress/ManagedCertificate enforce)."
  }

  validation {
    condition     = length(distinct([for d in var.n8n_additional_domains : lower(d)])) == length(var.n8n_additional_domains)
    error_message = "n8n_additional_domains must not contain duplicate hostnames (comparison is case-insensitive)."
  }

  validation {
    condition     = !contains([for d in var.n8n_additional_domains : lower(d)], lower(var.n8n_fqdn))
    error_message = "n8n_additional_domains must not repeat the canonical n8n_fqdn hostname."
  }

  validation {
    condition     = var.tls_mode != "google_managed" || (length(var.n8n_additional_domains) + 1) <= 100
    error_message = "tls_mode = google_managed supports at most 100 domains per ManagedCertificate (n8n_fqdn plus n8n_additional_domains). Reduce n8n_additional_domains or switch tls_mode."
  }
}

variable "ingress_annotations" {
  description = "Additional annotations merged onto the module-managed Ingress (kubernetes_ingress_v1.n8n in n8n.tf), e.g. for a third-party integration compatible with GKE's native gce Ingress controller. Must not set a module-owned key; use the dedicated tls_mode, ingress_ssl_policy_name, cloud_dns_zone_name, or ingress_source_cidrs inputs for TLS, SSL policy, DNS, and source-restriction ownership instead. Ignored (with a warning) when create_ingress = false."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition = alltrue([
      for k in keys(var.ingress_annotations) : !contains([
        "kubernetes.io/ingress.class",
        "kubernetes.io/ingress.global-static-ip-name",
        "networking.gke.io/v1beta1.FrontendConfig",
        "networking.gke.io/managed-certificates",
        "ingress.gcp.kubernetes.io/pre-shared-cert",
      ], k)
    ])
    error_message = "ingress_annotations must not set a module-owned annotation key (kubernetes.io/ingress.class, kubernetes.io/ingress.global-static-ip-name, networking.gke.io/v1beta1.FrontendConfig, networking.gke.io/managed-certificates, or ingress.gcp.kubernetes.io/pre-shared-cert). Use tls_mode, ingress_ssl_policy_name, cloud_dns_zone_name, or ingress_source_cidrs instead."
  }
}

# ── Managed-ingress security controls ─────────────────────────────────────
# All three are ignored when create_ingress = false (checks.tf emits the
# opposite-path diagnostic); a caller who owns ingress also owns any TLS
# policy or source restriction out of band.

variable "ingress_ssl_policy_name" {
  description = "Name of an existing Google Cloud SSL policy the managed ingress's target HTTPS proxy should use, e.g. to enforce TLS 1.2+ or a restricted cipher profile. Attached via the FrontendConfig CR's sslPolicy field (crds.tf). Leave null (the default) for GKE's default SSL policy. Ignored when create_ingress = false."
  type        = string
  default     = null
}

variable "ingress_source_cidrs" {
  description = "CIDR blocks allowed to reach n8n through the managed ingress. When non-empty, the module creates a Cloud Armor security policy (google_compute_security_policy.n8n) that allows only these CIDRs and denies every other source, attached to the ingress via BackendConfig.spec.securityPolicy (crds.tf). Every webhook sender must be included in this list, or their requests will be denied. Mutually exclusive with existing_cloud_armor_policy_name. Leave empty (the default) for no source restriction. Ignored when create_ingress = false."
  type        = list(string)
  default     = []
  nullable    = false
}

variable "existing_cloud_armor_policy_name" {
  description = "Name of an existing Cloud Armor security policy to attach to the managed ingress's BackendConfig instead of a module-created CIDR allow-list. Mutually exclusive with ingress_source_cidrs. Leave null (the default) for no existing policy. Ignored when create_ingress = false."
  type        = string
  default     = null

  validation {
    condition     = var.existing_cloud_armor_policy_name == null || length(var.ingress_source_cidrs) == 0
    error_message = "ingress_source_cidrs and existing_cloud_armor_policy_name are mutually exclusive: supply source CIDRs for a module-created Cloud Armor policy, or reference an existing policy, not both."
  }
}

# ── GKE ownership ──────────────────────────────────────────────────────────────

variable "create_gke" {
  description = "When true (the default), the module creates and manages the GKE cluster, node pool, node service account, and node IAM bindings. Set to false to deploy onto an existing regional GKE cluster; existing_gke_cluster_name and existing_gke_prerequisites_attestation must then be supplied."
  type        = bool
  default     = true
  nullable    = false
}

variable "existing_gke_cluster_name" {
  description = "Name of the existing regional GKE cluster (in gcp_region) to deploy n8n onto. Required when create_gke = false. Ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.create_gke || var.existing_gke_cluster_name != null
    error_message = "existing_gke_cluster_name is required when create_gke = false."
  }
}

# This attestation is only ever consumed by its own validation block below;
# tflint does not treat a variable's self-referential validation condition as
# a use.
# tflint-ignore: terraform_unused_declarations
variable "existing_gke_prerequisites_attestation" {
  description = "Explicit attestation that the existing GKE cluster named by existing_gke_cluster_name is reachable by the configured providers, uses VPC-native networking, has Workload Identity enabled, runs GKE's native ingress/metrics/autoscaling/PD CSI controllers, has capacity for the requested n8n workload, and grants this module permission to create namespaced resources. The module cannot safely audit these properties; it trusts this attestation. Required (must be true) when create_gke = false."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = var.create_gke || var.existing_gke_prerequisites_attestation
    error_message = "existing_gke_prerequisites_attestation must be true when create_gke = false, confirming the existing cluster meets the documented prerequisites."
  }
}

variable "existing_gke_workload_identity_pool" {
  description = "Workload Identity pool of the existing GKE cluster (normally <project_id>.svc.id.goog). Only needed when the existing cluster's Workload Identity pool belongs to a different Google Cloud project than project_id (a cross-project binding). Ignored when create_gke = true. Leave null to use <project_id>.svc.id.goog."
  type        = string
  default     = null
}

# ── GKE cluster + node pool ───────────────────────────────────────────────────

variable "gke_release_channel" {
  description = "GKE release channel: RAPID, REGULAR, STABLE, or UNSPECIFIED (to pin a version)."
  type        = string
  default     = "REGULAR"
}

variable "gke_min_master_version" {
  description = "Optional control-plane version prefix (e.g. \"1.32\"). Empty lets the release channel decide."
  type        = string
  default     = ""
}

variable "gke_deletion_protection" {
  description = "Block terraform destroy of the GKE cluster (google provider default is true)."
  type        = bool
  default     = true
}

variable "gke_enable_private_nodes" {
  description = "Give nodes private IPs only (egress via Cloud NAT). Control-plane endpoint stays public unless locked down via gke_control_plane_authorized_networks."
  type        = bool
  default     = true
}

variable "gke_control_plane_cidr" {
  description = "CIDR for the GKE control-plane peering range (private cluster). Must not overlap the subnet/pods/services ranges."
  type        = string
  default     = "172.16.0.0/28"
}

variable "gke_control_plane_authorized_networks" {
  description = "CIDRs allowed to reach the control-plane endpoint. Empty = open (dev only); set to your admin CIDRs for a locked-down control plane."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "gke_node_type" {
  description = "Node machine type."
  type        = string
  default     = "e2-standard-4"
}

variable "gke_node_min_per_zone" {
  description = "Autoscaling minimum nodes PER ZONE. A regional cluster spans ~3 zones, so total min is roughly this x3."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.gke_node_min_per_zone >= 0 && floor(var.gke_node_min_per_zone) == var.gke_node_min_per_zone
    error_message = "gke_node_min_per_zone must be a whole number of at least 0."
  }
}

variable "gke_node_max_per_zone" {
  description = "Autoscaling maximum nodes PER ZONE. GKE places a regional node pool in three zones by default, so the pool's ceiling is roughly three times this value. The default of 4 (12 e2-standard-4 nodes, 48 vCPUs) is the smallest ceiling whose estimated allocatable capacity covers the module's default main, worker, webhook, and task-runner replica maxima (see the capacity check blocks); it is a ceiling only, baseline cost is set by gke_node_min_per_zone. Reaching it needs at least 48 vCPUs of regional Compute Engine quota plus headroom for surge upgrades; new projects often start at 24."
  type        = number
  default     = 4
  nullable    = false

  validation {
    condition     = var.gke_node_max_per_zone >= 1 && floor(var.gke_node_max_per_zone) == var.gke_node_max_per_zone
    error_message = "gke_node_max_per_zone must be a whole number of at least 1."
  }

  validation {
    condition     = var.gke_node_max_per_zone >= var.gke_node_min_per_zone
    error_message = "gke_node_max_per_zone must be greater than or equal to gke_node_min_per_zone."
  }
}

variable "gke_node_disk_size_gb" {
  description = "Node boot disk size in GB."
  type        = number
  default     = 100
  nullable    = false

  validation {
    condition     = var.gke_node_disk_size_gb >= 10 && floor(var.gke_node_disk_size_gb) == var.gke_node_disk_size_gb
    error_message = "gke_node_disk_size_gb must be a whole number of at least 10, Google Cloud's minimum node boot-disk size."
  }
}

variable "gke_node_disk_type" {
  description = "Node boot disk type (pd-standard, pd-balanced, pd-ssd)."
  type        = string
  default     = "pd-balanced"
}

# ── GKE customer-managed encryption (Cloud KMS) ─────────────────────────────
# Same explicit create-or-reference contract as Cloud SQL, Memorystore, and
# GCS (D4): create_gke_kms_key creates a key in the shared ring
# (create_kms_key_ring/existing_kms_key_ring_id), existing_gke_kms_key_id
# references an already-existing key, and leaving both unset keeps GKE's
# default Google-managed etcd encryption. Only takes effect for a
# module-managed cluster; ignored when create_gke = false (checks.tf emits
# the ignored-input diagnostic).

variable "create_gke_kms_key" {
  description = "When true, the module creates a Cloud KMS CryptoKey in the shared key ring (see create_kms_key_ring/existing_kms_key_ring_id) and configures the module-managed GKE cluster's application-layer secrets encryption (etcd) to use it. Mutually exclusive with existing_gke_kms_key_id. Ignored when create_gke = false. Defaults to false (Google-managed etcd encryption). The created key is protected by lifecycle prevent_destroy; see docs/destroy-cleanup.md for how to back out of a module-created key."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.create_gke_kms_key || var.existing_gke_kms_key_id == null
    error_message = "create_gke_kms_key and existing_gke_kms_key_id are mutually exclusive; create a key or reference an existing one, not both."
  }
}

variable "existing_gke_kms_key_id" {
  description = "Fully qualified ID (projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>) of an existing Cloud KMS key the module-managed GKE cluster should use for application-layer secrets encryption (etcd). Mutually exclusive with create_gke_kms_key. The module grants no IAM on a supplied existing key; grant the GKE service agent (service-<project_number>@container-engine-robot.iam.gserviceaccount.com) roles/cloudkms.cryptoKeyEncrypterDecrypter on it out of band. Ignored when create_gke = false."
  type        = string
  default     = null

  validation {
    condition = var.existing_gke_kms_key_id == null || can(regex(
      "^projects/[^/]+/locations/[^/]+/keyRings/[^/]+/cryptoKeys/[^/]+$",
      var.existing_gke_kms_key_id,
    ))
    error_message = "existing_gke_kms_key_id must be null or a fully qualified Cloud KMS CryptoKey ID (projects/<project>/locations/<location>/keyRings/<ring>/cryptoKeys/<key>)."
  }

  validation {
    condition = var.existing_gke_kms_key_id == null ? true : (
      !var.create_gke || try(lower(split("/", var.existing_gke_kms_key_id)[3]), "") == lower(var.gcp_region)
    )
    error_message = "existing_gke_kms_key_id must be a regional key in gcp_region: the module-managed GKE cluster's application-layer secrets encryption requires the key and cluster to share a region. Ignored when create_gke = false."
  }
}

# ── GKE Secret Manager add-on ────────────────────────────────────────────────
# Opt-in GKE-managed CSI add-on (D7, mirrors n8n_secret_manager_enabled in
# secret_manager.tf, which grants n8n's own Workload Identity SA access to
# caller-named Secret Manager secrets for n8n's in-product External Secrets
# feature): this toggle instead enables the GKE-managed Secret Manager CSI
# driver component on the cluster itself, letting any pod mount Secret
# Manager secrets as files or sync them into the Kubernetes Secrets the
# existing `*_secret_ref` inputs already read (e.g.
# n8n_license_key_secret_ref, n8n_credentials_overwrite_secret_ref). Workload
# Identity (workload_identity.tf) already lets a Kubernetes ServiceAccount
# authenticate as a Google service account with Secret Manager IAM; this
# add-on is the cluster-side half of that pattern. The module grants no
# Secret Manager IAM here; the caller's pod-level Workload Identity SA needs
# roles/secretmanager.secretAccessor on its own secrets out of band (or via
# n8n_secret_manager_enabled's grant, for n8n's own External Secrets use).
# Only takes effect for a module-managed cluster; ignored when create_gke =
# false (checks.tf emits the ignored-input diagnostic).

variable "gke_secret_manager_addon_enabled" {
  description = "When true and create_gke is true, enables the GKE-managed Secret Manager CSI driver add-on (secret_manager_config) on the module-managed cluster, letting pods mount Google Secret Manager secrets or sync them into the Kubernetes Secrets the *_secret_ref inputs read. Defaults to false. Ignored when create_gke = false."
  type        = bool
  default     = false
  nullable    = false
}
