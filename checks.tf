# ── Opposite-path input diagnostics ───────────────────────────────────────────
# `check` blocks (Terraform 1.5+) emit a warning, not an error, when a tuning
# input is set only for the managed path but the caller has selected the
# corresponding customer-managed path. They never fail the plan: some callers
# legitimately keep managed-path tfvars around while trialling a
# customer-managed layer. Missing *required* references on the
# customer-managed path are enforced separately by hard `validation` blocks on
# the reference variables themselves (see variables.tf / variables_gcp.tf).
#
# Default coupling: Terraform cannot reference a variable's declared default,
# so the managed-path conditions below repeat each tuning variable's default
# as a literal. Changing a default in variables.tf / variables_gcp.tf must
# update the matching literal here, or the check fires falsely (or goes
# silently stale).

check "network_tuning_ignored_when_existing" {
  assert {
    condition = var.create_network || (
      var.subnet_cidr == "10.10.0.0/20" &&
      var.pods_cidr == "10.20.0.0/16" &&
      var.services_cidr == "10.30.0.0/20"
    )
    error_message = "create_network is false, but one or more managed-network tuning variables (subnet_cidr, pods_cidr, services_cidr) differ from their defaults. These are ignored when the module attaches to an existing network; set them on the existing network out of band instead."
  }
}

# create_psa is gated independently of create_network (D2: the module can
# manage the PSA connection on either a module-managed or an existing
# network), so its tuning input gets its own opposite-path diagnostic rather
# than being folded into network_tuning_ignored_when_existing above.
check "psa_tuning_ignored_when_existing" {
  assert {
    condition     = var.create_psa || var.psa_prefix_length == 16
    error_message = "create_psa is false, but psa_prefix_length differs from its default. This is ignored when the module does not manage the Private Service Access allocation; size the existing connection out of band instead."
  }
}

# Opposite-path diagnostic for the managed-network branch: existing-network
# reference variables are meaningless once the module owns the VPC/subnetwork.
check "network_references_ignored_when_managed" {
  assert {
    condition = !var.create_network || (
      var.existing_network_name == null &&
      var.existing_network_project_id == null &&
      var.existing_subnetwork_name == null &&
      var.existing_pods_range_name == null &&
      var.existing_services_range_name == null
    )
    error_message = "create_network is true, but one or more existing_network_*/existing_subnetwork_name/existing_pods_range_name/existing_services_range_name references are set. These are ignored when the module creates and manages the network; unset them or set create_network = false to attach to an existing network."
  }
}

# Opposite-path diagnostic for the managed-GKE branch, mirroring
# network_references_ignored_when_managed above: existing-cluster reference
# and attestation inputs are meaningless once the module owns the cluster, and
# a stray existing_gke_workload_identity_pool in particular must never rewrite
# the managed cluster's Workload Identity binding (locals.tf pins the managed
# branch to this project's own pool).
check "gke_references_ignored_when_managed" {
  assert {
    condition = !var.create_gke || (
      var.existing_gke_cluster_name == null &&
      var.existing_gke_workload_identity_pool == null &&
      !var.existing_gke_prerequisites_attestation
    )
    error_message = "create_gke is true, but one or more existing-cluster references (existing_gke_cluster_name, existing_gke_workload_identity_pool, existing_gke_prerequisites_attestation) are set. These are ignored when the module creates and manages the cluster; unset them or set create_gke = false to deploy onto an existing cluster."
  }
}

check "gke_tuning_ignored_when_existing" {
  assert {
    condition = var.create_gke || (
      var.gke_release_channel == "REGULAR" &&
      var.gke_min_master_version == "" &&
      var.gke_deletion_protection == true &&
      var.gke_enable_private_nodes == true &&
      var.gke_node_type == "e2-standard-4" &&
      var.gke_node_min_per_zone == 1 &&
      var.gke_node_max_per_zone == 4 &&
      var.gke_node_disk_size_gb == 100 &&
      var.gke_node_disk_type == "pd-balanced"
    )
    error_message = "create_gke is false, but one or more managed-GKE tuning variables (gke_release_channel, gke_min_master_version, gke_deletion_protection, gke_enable_private_nodes, gke_node_type, gke_node_min_per_zone, gke_node_max_per_zone, gke_node_disk_size_gb, gke_node_disk_type) differ from their defaults. These are ignored when deploying onto an existing cluster; configure the existing cluster's node pools out of band instead."
  }
}

check "postgres_tuning_ignored_when_external" {
  assert {
    condition = var.create_postgres_instance || (
      var.postgres_version == "POSTGRES_16" &&
      var.postgres_edition == "ENTERPRISE" &&
      var.postgres_machine_type == "db-g1-small" &&
      var.postgres_availability_type == "REGIONAL" &&
      var.postgres_disk_size == 50 &&
      var.postgres_deletion_protection == true &&
      var.postgres_backup_retained_backups == null &&
      var.postgres_transaction_log_retention_days == null &&
      var.postgres_query_logging_enabled == false &&
      var.postgres_ssl_mode == "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    )
    error_message = "create_postgres_instance is false, but one or more managed-Cloud-SQL tuning variables (postgres_version, postgres_edition, postgres_machine_type, postgres_availability_type, postgres_disk_size, postgres_deletion_protection, postgres_backup_retained_backups, postgres_transaction_log_retention_days, postgres_query_logging_enabled, postgres_ssl_mode) differ from their defaults. These are ignored when using an external database; configure the external service out of band instead."
  }
}

check "postgres_host_and_password_ignored_when_managed" {
  assert {
    condition = !var.create_postgres_instance || (
      var.n8n_database_host == null &&
      var.n8n_database_password == null &&
      var.n8n_database_password_secret_ref == null &&
      var.db_postgresdb_ssl_ca_pem == null
    )
    error_message = "create_postgres_instance is true, but n8n_database_host, n8n_database_password, n8n_database_password_secret_ref, or db_postgresdb_ssl_ca_pem is set. These are ignored for the module-managed instance; the module generates its own password and reports the instance's private IP via the postgres_host output, and db_postgresdb_ssl_reject_unauthorized (the only thing that uses the CA) is itself rejected on the managed path."
  }
}

# The CA is passed to the chart only while server-certificate verification is
# on (locals.tf, postgres_ssl_ca_active). The managed path is already covered by
# postgres_host_and_password_ignored_when_managed above, so this check only
# fires on the external path.
check "postgres_ssl_ca_ignored_without_verification" {
  assert {
    condition     = var.create_postgres_instance || var.db_postgresdb_ssl_ca_pem == null || var.db_postgresdb_ssl_reject_unauthorized
    error_message = "db_postgresdb_ssl_ca_pem is set, but db_postgresdb_ssl_reject_unauthorized is false, so the module does not pass the CA to the n8n chart and n8n does not verify the PostgreSQL server certificate. Set db_postgresdb_ssl_reject_unauthorized = true (with db_postgresdb_ssl_enabled = true) to use the CA, or remove db_postgresdb_ssl_ca_pem."
  }
}

# Without a CA bundle, n8n passes `ssl: true` to its PostgreSQL driver, so the
# certificate check follows Node's process-wide default, which
# NODE_TLS_REJECT_UNAUTHORIZED=0 turns off. With a CA bundle, n8n passes an
# explicit rejectUnauthorized and the variable has no effect on this
# connection. See docs/postgresql-tls.md.
check "postgres_ssl_verification_disabled_by_node_tls_env" {
  assert {
    condition = !(var.db_postgresdb_ssl_reject_unauthorized && var.db_postgresdb_ssl_ca_pem == null) || !anytrue([
      for e in concat(var.n8n_extra_env, var.n8n_worker_extra_env, flatten([for p in var.n8n_worker_pools : p.extra_env])) :
      e.name == "NODE_TLS_REJECT_UNAUTHORIZED" && e.value == "0"
    ])
    error_message = "db_postgresdb_ssl_reject_unauthorized = true without db_postgresdb_ssl_ca_pem, but n8n_extra_env, n8n_worker_extra_env, or an n8n_worker_pools entry's extra_env sets NODE_TLS_REJECT_UNAUTHORIZED=0. On the affected pods, Node then skips the PostgreSQL server-certificate check. Remove that entry, or supply the CA through db_postgresdb_ssl_ca_pem so n8n passes an explicit rejectUnauthorized."
  }
}

check "postgres_kms_ignored_when_external" {
  assert {
    condition = var.create_postgres_instance || (
      !var.create_postgres_kms_key &&
      var.existing_postgres_kms_key_id == null
    )
    error_message = "create_postgres_instance is false, but create_postgres_kms_key or existing_postgres_kms_key_id is set. These are ignored for an external database; the module never manages encryption for a customer-managed PostgreSQL instance."
  }
}

# Not a hard failure (D4's restore requirement only warns): when the module
# manages the core Secret without a caller-supplied direct key, it generates a
# brand-new n8n encryption key, so any restored/cloned credentials need the
# original key restored out of band. A caller-supplied direct n8n_encryption_key
# or an existing (customer-managed) core Secret already provides that
# continuity and needs no warning; this only proves a continuity path was
# supplied, not that the key actually matches the restored/cloned database.
check "postgres_restore_without_encryption_key_continuity" {
  assert {
    condition = (
      !local.manage_core_secret ||
      var.n8n_encryption_key != null ||
      (var.postgres_clone_source_instance_name == null && var.postgres_restore_backup_run_id == null)
    )
    error_message = "A restore or clone source is set for the module-managed Cloud SQL instance, but this module would generate a new random n8n encryption key rather than accepting an existing one. Any n8n credentials already encrypted in the restored/cloned database will be unreadable with the new key unless you supply the original deployment's key via n8n_encryption_key or existing_n8n_core_secret_name before starting n8n."
  }
}

check "redis_tuning_ignored_when_existing" {
  assert {
    condition = var.create_redis_instance || (
      var.redis_tier == "BASIC" &&
      var.redis_memory_size_gb == 1 &&
      var.redis_version == "REDIS_7_2" &&
      var.redis_auth_enabled == false &&
      var.redis_transit_encryption_enabled == false &&
      var.redis_maxmemory_policy == "noeviction" &&
      var.redis_persistence_enabled == false &&
      var.redis_rdb_snapshot_period == "TWENTY_FOUR_HOURS" &&
      var.redis_rdb_snapshot_start_time == null
    )
    error_message = "create_redis_instance is false, but one or more managed-Memorystore tuning variables (redis_tier, redis_memory_size_gb, redis_version, redis_auth_enabled, redis_transit_encryption_enabled, redis_maxmemory_policy, redis_persistence_enabled, redis_rdb_snapshot_period, redis_rdb_snapshot_start_time) differ from their defaults. These are ignored when using an external Redis host; configure the external service out of band instead."
  }
}

# redis_persistence_enabled itself is covered by redis_tuning_ignored_when_existing
# above; this check separately flags snapshot-schedule tuning left set while
# persistence is disabled on a module-managed instance (RDB is off either way,
# so the schedule inputs are ignored).
check "redis_persistence_tuning_ignored_when_disabled" {
  assert {
    condition = var.redis_persistence_enabled || (
      var.redis_rdb_snapshot_period == "TWENTY_FOUR_HOURS" &&
      var.redis_rdb_snapshot_start_time == null
    )
    error_message = "redis_persistence_enabled is false, but redis_rdb_snapshot_period or redis_rdb_snapshot_start_time differs from its default. These are ignored while Memorystore RDB persistence is disabled."
  }
}

check "redis_external_settings_ignored_when_managed" {
  assert {
    condition = !var.create_redis_instance || (
      var.redis_host == null &&
      var.redis_port == 6379 &&
      var.redis_tls_enabled == false &&
      var.redis_username == null &&
      var.redis_password == null &&
      var.redis_password_secret_ref == null
    )
    error_message = "create_redis_instance is true, but one or more external-Redis inputs (redis_host, redis_port, redis_tls_enabled, redis_username, redis_password, redis_password_secret_ref) are set. These are ignored for the module-managed Memorystore instance; use redis_auth_enabled and redis_transit_encryption_enabled instead."
  }
}

check "redis_kms_ignored_when_external" {
  assert {
    condition = var.create_redis_instance || (
      !var.create_redis_kms_key &&
      var.existing_redis_kms_key_id == null
    )
    error_message = "create_redis_instance is false, but create_redis_kms_key or existing_redis_kms_key_id is set. These are ignored for an external Redis host; the module never manages encryption for a customer-managed Redis instance."
  }
}

check "gcs_tuning_ignored_when_existing" {
  assert {
    condition = var.create_gcs_bucket || (
      var.gcs_location == "EU" &&
      var.gcs_force_destroy == false
    )
    error_message = "create_gcs_bucket is false, but one or more managed-bucket tuning variables (gcs_location, gcs_force_destroy) differ from their defaults. These are ignored when using an existing bucket; configure the existing bucket out of band instead."
  }
}

check "gcs_kms_ignored_when_existing" {
  assert {
    condition = var.create_gcs_bucket || (
      !var.create_gcs_kms_key &&
      var.existing_gcs_kms_key_id == null
    )
    error_message = "create_gcs_bucket is false, but create_gcs_kms_key or existing_gcs_kms_key_id is set. These are ignored for an existing bucket; the module never mutates an existing bucket's encryption."
  }
}

# Opposite-path diagnostic for section 11 (ingress ownership): every
# managed-ingress tuning and security-control input is ignored once the
# caller owns ingress, DNS, and TLS out of band (D9).
check "ingress_tuning_ignored_when_existing" {
  assert {
    condition = var.create_ingress || (
      var.tls_mode == "google_managed" &&
      var.https_redirect == true &&
      var.cloud_dns_zone_name == "" &&
      var.ingress_ssl_policy_name == null &&
      length(var.ingress_source_cidrs) == 0 &&
      var.existing_cloud_armor_policy_name == null
    )
    error_message = "create_ingress is false, but one or more managed-ingress tuning variables (tls_mode, https_redirect, cloud_dns_zone_name, ingress_ssl_policy_name, ingress_source_cidrs, existing_cloud_armor_policy_name) differ from their defaults. These are ignored when the caller owns ingress, DNS, and TLS; configure them on the caller-managed ingress out of band instead."
  }
}

# Opposite-path diagnostic for section 20.1 (guarded ingress annotations):
# ingress_annotations only ever merges onto kubernetes_ingress_v1.n8n
# (n8n.tf), which does not exist when the caller owns ingress out of band.
# n8n_additional_domains is intentionally not included here: its effective
# host list (n8n_ingress_hosts output) stays meaningful for a
# customer-managed ingress even though the module creates no DNS/certificate
# resources for it on this path (design.md, decision 7).
check "ingress_annotations_ignored_when_existing" {
  assert {
    condition     = var.create_ingress || length(var.ingress_annotations) == 0
    error_message = "create_ingress is false, but ingress_annotations is set. These annotations only apply to the module-managed Ingress; they are ignored when the caller owns ingress out of band."
  }
}

# The chart only renders autoscaling.keda.sh/paused-replicas while the
# ScaledObject is paused (templates/_helpers.tpl, n8n.kedaAnnotations), so a
# held count without n8n_worker_keda_pause = true is silently inert. Same
# check name as terraform-aws-n8n / terraform-azurerm-n8n.
check "worker_keda_paused_replica_count_requires_pause" {
  assert {
    condition     = var.n8n_worker_keda_paused_replica_count == null ? true : var.n8n_worker_keda_pause
    error_message = "n8n_worker_keda_paused_replica_count is set while n8n_worker_keda_pause is false. The chart only renders autoscaling.keda.sh/paused-replicas while the worker ScaledObject is paused, so the count is inert. Set n8n_worker_keda_pause = true or clear the count."
  }
}

# Pause is only reliable from chart 1.13.0 (local.n8n_worker_keda_pause_supported
# in scaling.tf): older charts ignore it, and 1.12.0 re-renders the worker's
# spec.replicas on every Helm upgrade, overriding a held count. Skipped for a
# custom n8n_chart_repository. Same check name as terraform-aws-n8n.
check "worker_keda_pause_requires_a_supported_chart" {
  assert {
    condition     = (var.n8n_worker_keda_pause || var.n8n_worker_keda_paused_replica_count != null) ? local.n8n_worker_keda_pause_supported : true
    error_message = "n8n_worker_keda_pause or n8n_worker_keda_paused_replica_count is set, but n8n_chart_version predates 1.13.0. Charts older than 1.12.0 do not read keda.worker.pause at all. Chart 1.12.0 reads it but still sets the worker Deployment's spec.replicas on every Helm upgrade, so any later apply while paused can write the replica floor back over the held count. Bump n8n_chart_version to 1.13.0 or newer, or clear these inputs."
  }
}

# The warning half of the shutdown-window rule. An explicit
# n8n_graceful_shutdown_timeout that does not fit is a hard validation error on
# that variable (variables_gcp.tf). Left null, the chart still renders its own
# default, which must fit the same way, but this was never checked before that
# input existed, so a hard error here would break configurations that already
# plan. Skipped for a custom n8n_chart_repository, whose values.yaml default
# this module cannot verify (local.n8n_graceful_shutdown_default_applies); the
# explicit-value validation still applies there, because it does not depend
# on the chart's default. Same check name as terraform-aws-n8n.
check "graceful_shutdown_fits_grace_period" {
  assert {
    condition     = local.n8n_graceful_shutdown_default_applies ? (local.n8n_chart_default_graceful_shutdown_timeout + var.n8n_prestop_sleep < var.n8n_termination_grace_period) : true
    error_message = "n8n_graceful_shutdown_timeout is unset, so n8n uses the chart's default shutdown timeout of ${local.n8n_chart_default_graceful_shutdown_timeout}s. That plus n8n_prestop_sleep (${var.n8n_prestop_sleep}s) does not stay below n8n_termination_grace_period (${var.n8n_termination_grace_period}s), so Kubernetes can SIGKILL a pod before n8n finishes shutting down and interrupt running executions. Set n8n_graceful_shutdown_timeout to a value that fits, lower n8n_prestop_sleep, or raise n8n_termination_grace_period."
  }
}

# ── Diagnostics: PostgreSQL connection budget vs. known Cloud SQL defaults ───
# Opt-in (postgres_connection_budget_check_enabled, default false): the
# module's own default autoscaler ceilings already exceed db-g1-small's
# known budget (see below), so this stays off until a caller has settled on
# both a postgres_machine_type and replica ceilings and wants this advisory
# guard against a later regression. Cloud SQL for PostgreSQL automatically
# manages max_connections from the instance's current memory and
# recalculates it whenever postgres_machine_type changes (the instance
# restarts, and read replicas may restart too; see docs/sandbox.md and
# https://cloud.google.com/sql/docs/postgres/instance-settings). This check
# only evaluates the budget for the postgres_machine_type in the current
# plan, not any prior value.
# This check catches the arithmetic db_postgresdb_pool_size's own
# description already asks callers to budget by hand: pool size times the
# modeled pod ceiling (effective main, worker, webhook-processor, and any
# n8n_worker_pools, mirroring capacity.tf's own capacity_main_max_replicas /
# capacity_worker_max_replicas / capacity_webhook_max_replicas
# replica-ceiling locals, reused here rather than duplicated) against
# Google's own published default-by-memory table.
#
# Source (checked 2026-10-01): https://cloud.google.com/sql/docs/postgres/flags,
# the max_connections row: "The default value depends on the amount of
# memory of the largest instance in the chain of primaries":
#   Memory (GB) on largest instance | Default value
#   tiny (~0.5)                     | 25   (db-f1-micro)
#   small (~1.7)                    | 50   (db-g1-small)
#   3.75 to < 6                     | 100
#   6 to < 7.5                      | 200
#   7.5 to < 15                     | 400
#   15 to < 30                      | 500
#   30 to < 60                      | 600
#   60 to < 120                     | 800
#   >= 120                          | 1,000
# db-f1-micro/db-g1-small (the legacy shared-core tiers, including this
# module's own postgres_machine_type default) match the "tiny"/"small" rows
# literally. Enterprise-edition custom tiers derive their memory from the
# db-custom-<vcpus>-<memory_mb> naming convention, which Google documents as
# encoding memory in MiB directly in the name (see
# https://cloud.google.com/sql/docs/postgres/instance-settings, "Machine
# Type", and https://cloud.google.com/compute/docs/instances/creating-instance-with-custom-machine-type
# for the underlying Compute Engine convention Cloud SQL reuses). regex()
# is wrapped in try() because Terraform 1.9 does not short-circuit && / ||
# (AGENTS.md); a non-matching string must not raise an error here. With
# exactly one capture group, regex() returns a one-element list (not a bare
# string), hence the [0] index before tonumber(). ENTERPRISE_PLUS
# db-perf-optimized-N-<vcpus> tiers (N2 machine series) have a fixed,
# Google-documented vCPU-to-memory table (not a uniform per-vCPU ratio, e.g.
# the 128-vCPU shape is 864 GB rather than 1,024 GB); see
# https://cloud.google.com/sql/docs/postgres/machine-series-overview, "N2
# machine types". That table is reproduced in
# postgres_perf_optimized_n_memory_gb below. Every other recognized shape
# (other ENTERPRISE_PLUS series such as C4/C4A, and predefined series such
# as n2-standard-<N>) is not covered: deriving memory for those reliably
# would need a second per-series table this change does not add, so they
# resolve to null (silent) rather than a guessed bucket. The check is also
# silent when create_postgres_instance = false (no module-managed instance
# to size) or postgres_connection_budget_check_enabled = false.
#
# This is an optimistic threshold, so a silent check does not prove the
# ceilings fit:
#   - The table holds the raw max_connections default, not the connections
#     n8n can use. PostgreSQL carves superuser_reserved_connections out of
#     max_connections, the module's database user is not a real superuser,
#     and every other client of the instance shares the rest. Google does
#     not document how many slots Cloud SQL itself reserves, so nothing is
#     subtracted here (terraform-aws-n8n subtracts measured RDS reserves;
#     terraform-azurerm-n8n uses Microsoft's published user limits).
#   - The model counts configured steady-state ceilings. Extra pods a
#     rolling update adds are not counted.
#   - With n8n_main_hpa_enabled, n8n_worker_keda_enabled, or
#     n8n_webhook_hpa_enabled set to false, the model counts that role's
#     fixed replica count (capacity.tf). A caller-owned autoscaler can scale
#     past it.
#   - The module manages database_flags without ignore_changes, so a
#     max_connections flag set outside Terraform is removed on the next apply.
locals {
  postgres_machine_type_custom_memory_mb = try(
    tonumber(regex("^db-custom-[0-9]+-([0-9]+)$", var.postgres_machine_type)[0]),
    null
  )

  # Google-documented N2 machine series table (db-perf-optimized-N-<vcpus>),
  # https://cloud.google.com/sql/docs/postgres/machine-series-overview.
  postgres_perf_optimized_n_memory_gb = {
    "2"   = 16
    "4"   = 32
    "8"   = 64
    "16"  = 128
    "32"  = 256
    "48"  = 384
    "64"  = 512
    "80"  = 640
    "96"  = 768
    "128" = 864
  }

  postgres_machine_type_perf_optimized_n_vcpus = try(
    regex("^db-perf-optimized-N-([0-9]+)$", var.postgres_machine_type)[0],
    null
  )

  postgres_machine_type_perf_optimized_n_memory_mb = local.postgres_machine_type_perf_optimized_n_vcpus == null ? null : (
    lookup(local.postgres_perf_optimized_n_memory_gb, local.postgres_machine_type_perf_optimized_n_vcpus, null) == null ? null :
    local.postgres_perf_optimized_n_memory_gb[local.postgres_machine_type_perf_optimized_n_vcpus] * 1024
  )

  postgres_machine_type_memory_mb = (
    local.postgres_machine_type_custom_memory_mb != null ? local.postgres_machine_type_custom_memory_mb :
    local.postgres_machine_type_perf_optimized_n_memory_mb
  )

  postgres_max_user_connections_known = (
    var.postgres_machine_type == "db-f1-micro" ? 25 :
    var.postgres_machine_type == "db-g1-small" ? 50 :
    local.postgres_machine_type_memory_mb == null ? null :
    local.postgres_machine_type_memory_mb < 6144 ? 100 :
    local.postgres_machine_type_memory_mb < 7680 ? 200 :
    local.postgres_machine_type_memory_mb < 15360 ? 400 :
    local.postgres_machine_type_memory_mb < 30720 ? 500 :
    local.postgres_machine_type_memory_mb < 61440 ? 600 :
    local.postgres_machine_type_memory_mb < 122880 ? 800 :
    1000
  )

  # sum()'s [0] seed keeps the no-pools default at 0 rather than erroring on
  # an empty list (mirrors capacity.tf's capacity_pool_peak_* pattern).
  n8n_worker_pools_max_replicas_sum = sum(concat([0], [for p in var.n8n_worker_pools : p.max_replicas]))

  # While n8n_worker_keda_pause is true, KEDA holds the worker Deployment at
  # n8n_worker_keda_paused_replica_count, which may exceed the KEDA maximum.
  # Pause only applies while the module manages the worker ScaledObject
  # (n8n_worker_keda_enabled = true). A null count freezes workers at their
  # current count, which the model assumes is within the maximum. Same model
  # as terraform-azurerm-n8n.
  n8n_postgres_worker_modeled_max_replicas = (var.n8n_worker_keda_enabled && var.n8n_worker_keda_pause) ? max(
    local.capacity_worker_max_replicas,
    coalesce(var.n8n_worker_keda_paused_replica_count, 0),
  ) : local.capacity_worker_max_replicas

  n8n_postgres_peak_connections = var.db_postgresdb_pool_size * (
    local.capacity_main_max_replicas +
    local.n8n_postgres_worker_modeled_max_replicas +
    local.capacity_webhook_max_replicas +
    local.n8n_worker_pools_max_replicas_sum
  )
}

check "postgres_pool_size_fits_known_max_connections" {
  assert {
    condition = (var.postgres_connection_budget_check_enabled && var.create_postgres_instance && local.postgres_max_user_connections_known != null) ? (
      local.n8n_postgres_peak_connections <= local.postgres_max_user_connections_known
    ) : true
    error_message = join("", [
      "db_postgresdb_pool_size (${var.db_postgresdb_pool_size}) times the modeled pod ceiling (main ",
      "${local.capacity_main_max_replicas} + worker ${local.n8n_postgres_worker_modeled_max_replicas} + webhook ",
      tostring(local.capacity_webhook_max_replicas),
      local.n8n_worker_pools_max_replicas_sum > 0 ? " + worker pools ${local.n8n_worker_pools_max_replicas_sum}" : "",
      ") demands up to ${local.n8n_postgres_peak_connections} connections at full scale-out, more than the ",
      "default max_connections of ${coalesce(local.postgres_max_user_connections_known, 0)} that Cloud SQL sets for postgres_machine_type = ",
      # jsonencode() keeps a null machine type from failing the plan: Terraform
      # evaluates error_message even while the condition passes, and a null
      # value in a string template is an error.
      jsonencode(var.postgres_machine_type),
      ". Cloud SQL derives this from the machine type's memory and recalculates it when postgres_machine_type ",
      "changes. Reserved superuser slots and other clients also count against it, so n8n can use fewer. Fix with ",
      "one of: (1) lower db_postgresdb_pool_size, (2) lower the main/worker/webhook-processor autoscaler maxima ",
      "(or the fixed replica counts of any role whose autoscaler is disabled, any n8n_worker_pools max_replicas, ",
      "or n8n_worker_keda_paused_replica_count), or (3) move to a larger ",
      "postgres_machine_type. Confirm the live value with SHOW max_connections (see docs/sandbox.md). This ",
      "diagnostic is advisory and does not fail the plan.",
    ])
  }
}
