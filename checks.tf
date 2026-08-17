# ── Opposite-path input diagnostics ───────────────────────────────────────────
# `check` blocks (Terraform 1.5+) emit a warning, not an error, when a tuning
# input is set only for the managed path but the caller has selected the
# corresponding customer-managed path. They never fail the plan: some callers
# legitimately keep managed-path tfvars around while trialling a
# customer-managed layer. Missing *required* references on the
# customer-managed path are enforced separately by hard `validation` blocks on
# the reference variables themselves (see variables.tf / variables_gcp.tf).

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

check "gke_tuning_ignored_when_existing" {
  assert {
    condition = var.create_gke || (
      var.gke_release_channel == "REGULAR" &&
      var.gke_min_master_version == "" &&
      var.gke_deletion_protection == true &&
      var.gke_enable_private_nodes == true &&
      var.gke_node_type == "e2-standard-4" &&
      var.gke_node_min_per_zone == 1 &&
      var.gke_node_max_per_zone == 2 &&
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
      var.postgres_deletion_protection == true
    )
    error_message = "create_postgres_instance is false, but one or more managed-Cloud-SQL tuning variables (postgres_version, postgres_edition, postgres_machine_type, postgres_availability_type, postgres_disk_size, postgres_deletion_protection) differ from their defaults. These are ignored when using an external database; configure the external service out of band instead."
  }
}

check "postgres_host_and_password_ignored_when_managed" {
  assert {
    condition = !var.create_postgres_instance || (
      var.n8n_database_host == null &&
      var.n8n_database_password == null &&
      var.n8n_database_password_secret_ref == null
    )
    error_message = "create_postgres_instance is true, but n8n_database_host, n8n_database_password, or n8n_database_password_secret_ref is set. These are ignored for the module-managed instance; the module generates its own password and reports the instance's private IP via the postgres_host output."
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
# manages the core Secret it generates a brand-new n8n encryption key, so any
# restored/cloned credentials need the original key restored out of band. An
# existing core Secret already provides that continuity and needs no warning.
check "postgres_restore_without_encryption_key_continuity" {
  assert {
    condition     = !local.manage_core_secret || (var.postgres_clone_source_instance_name == null && var.postgres_restore_backup_run_id == null)
    error_message = "A restore or clone source is set for the module-managed Cloud SQL instance, but this module always generates a new random n8n encryption key rather than accepting an existing one. Any n8n credentials already encrypted in the restored/cloned database will be unreadable with the new key unless you manually restore the original deployment's n8n_encryption_key output into the new instance's encryptionKey Secret before starting n8n."
  }
}

check "redis_tuning_ignored_when_existing" {
  assert {
    condition = var.create_redis_instance || (
      var.redis_tier == "BASIC" &&
      var.redis_memory_size_gb == 1 &&
      var.redis_version == "REDIS_7_2" &&
      var.redis_auth_enabled == false &&
      var.redis_transit_encryption_enabled == false
    )
    error_message = "create_redis_instance is false, but one or more managed-Memorystore tuning variables (redis_tier, redis_memory_size_gb, redis_version, redis_auth_enabled, redis_transit_encryption_enabled) differ from their defaults. These are ignored when using an external Redis host; configure the external service out of band instead."
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
