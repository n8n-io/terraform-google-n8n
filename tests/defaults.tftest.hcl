# Plan-time tests for the terraform-google-n8n module using mocked providers.
#
# Exercises the module end-to-end (GKE, Cloud SQL, Memorystore, GCS, KEDA, the
# n8n Helm release) without contacting Google Cloud. All providers are mocked,
# so no credentials or network access are required and the suite runs offline.
#
# Run: terraform test
#   (from the module root - requires terraform >= 1.9)
#
# Two kinds of assertion appear below:
#   * Resource-level: static (plan-time-known) attributes of the resources the
#     module creates - names, tiers, machine types, private-networking flags.
#   * Variable-contract: the value and validation behaviour of input variables
#     whose effect lands inside the n8n Helm release. The Helm values blob is a
#     JSON-encoded string that depends on kubernetes_namespace (unknown at plan
#     time under the mock provider), so those inputs are asserted at the
#     variable layer; their wiring into config.extraEnv is covered by a real
#     terraform plan from an example root.

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  project_id           = "test-project"
  gcp_region           = "us-east4"
  friendly_name_prefix = "test"
  n8n_fqdn             = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"
}

run "defaults_produce_valid_plan" {
  command = plan

  assert {
    condition     = google_container_cluster.n8n[0].name == "test-n8n"
    error_message = "friendly_name_prefix should flow through to google_container_cluster.name as <friendly_name_prefix>-n8n"
  }

  # common_labels entries must appear in a labeled resource's merged label set.
  assert {
    condition     = google_container_cluster.n8n[0].resource_labels["managed_by"] == "terraform"
    error_message = "resource_labels must include the module's built-in labels"
  }

  # VPC-native (alias IP) networking is required for private Cloud SQL/Redis
  # over Private Service Access and for Workload Identity to function.
  assert {
    condition     = google_container_cluster.n8n[0].networking_mode == "VPC_NATIVE"
    error_message = "cluster must be VPC-native so alias IPs and PSA work"
  }

  assert {
    condition     = google_container_cluster.n8n[0].release_channel[0].channel == "REGULAR"
    error_message = "gke_release_channel should default to REGULAR"
  }

  # Workload Identity pool must be the project's fixed <project>.svc.id.goog
  # identity namespace; without it the KSA->GSA binding cannot resolve.
  assert {
    condition     = google_container_cluster.n8n[0].workload_identity_config[0].workload_pool == "test-project.svc.id.goog"
    error_message = "workload_identity_config must bind the project's svc.id.goog pool"
  }

  assert {
    condition     = google_container_node_pool.n8n[0].node_config[0].machine_type == "e2-standard-4"
    error_message = "gke_node_type should default to e2-standard-4"
  }

  # Regional cluster: min/max are per-zone counts applied across the region's
  # zones. Defaults keep a small footprint that autoscaling can grow.
  assert {
    condition     = google_container_node_pool.n8n[0].autoscaling[0].min_node_count == 1
    error_message = "gke_node_min_per_zone should default to 1"
  }

  assert {
    condition     = google_container_node_pool.n8n[0].autoscaling[0].max_node_count == 4
    error_message = "gke_node_max_per_zone should default to 4, the smallest ceiling whose estimated capacity covers the default replica maxima"
  }
}

run "cloudsql_private_and_hardened" {
  command = plan

  assert {
    condition     = google_sql_database_instance.n8n[0].database_version == "POSTGRES_16"
    error_message = "postgres_version should default to POSTGRES_16"
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].tier == "db-g1-small"
    error_message = "postgres_machine_type should default to db-g1-small"
  }

  # Regional availability is the point of the module's HA posture.
  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].availability_type == "REGIONAL"
    error_message = "postgres_availability_type should default to REGIONAL for HA"
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].disk_type == "PD_SSD"
    error_message = "Cloud SQL should use PD_SSD storage"
  }

  # Private IP only: the instance must NOT get a public IPv4 address; it is
  # reachable solely over the VPC via Private Service Access.
  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].ip_configuration[0].ipv4_enabled == false
    error_message = "Cloud SQL must NOT have a public IP (ipv4_enabled must be false)"
  }

  # n8n connects with DB_POSTGRESDB_SSL_ENABLED=false, so the instance must
  # accept unencrypted connections over the private path.
  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].ip_configuration[0].ssl_mode == "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    error_message = "Cloud SQL ssl_mode must match n8n's DB_POSTGRESDB_SSL_ENABLED=false path"
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].backup_configuration[0].enabled == true
    error_message = "Cloud SQL automated backups must be enabled"
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].backup_configuration[0].point_in_time_recovery_enabled == true
    error_message = "Cloud SQL point-in-time recovery must be enabled"
  }
}

# Cross-variable validation: when the caller opts into an external database
# (create_postgres_instance = false), both n8n_database_host and
# n8n_database_password are required at plan time. Without these the failure
# would otherwise surface deep inside the n8n Helm release at apply time,
# after the cluster and database have been built.

run "external_db_missing_host_fails_validation" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_password    = "external-db-password"
    # n8n_database_host intentionally unset
  }

  expect_failures = [var.n8n_database_host]
}

run "external_db_missing_password_fails_validation" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    # n8n_database_password and n8n_database_password_secret_ref intentionally unset
  }

  expect_failures = [var.n8n_database_password_secret_ref]
}

run "redis_private_and_sized" {
  command = plan

  assert {
    condition     = google_redis_instance.n8n[0].tier == "BASIC"
    error_message = "redis_tier should default to BASIC"
  }

  assert {
    condition     = google_redis_instance.n8n[0].memory_size_gb == 1
    error_message = "redis_memory_size_gb should default to 1"
  }

  # Redis must be reached over Private Service Access, never a public endpoint.
  assert {
    condition     = google_redis_instance.n8n[0].connect_mode == "PRIVATE_SERVICE_ACCESS"
    error_message = "Redis connect_mode must be PRIVATE_SERVICE_ACCESS"
  }

  assert {
    condition     = google_redis_instance.n8n[0].transit_encryption_mode == "DISABLED"
    error_message = "Redis transit_encryption_mode should default to DISABLED (private VPC path)"
  }
}

run "gcs_bucket_is_private" {
  command = plan

  # Uniform bucket-level access disables per-object ACLs, so access is governed
  # only by IAM - the GCS equivalent of blocking public ACLs.
  assert {
    condition     = google_storage_bucket.n8n[0].uniform_bucket_level_access == true
    error_message = "GCS bucket must use uniform bucket-level access (IAM-only, no object ACLs)"
  }

  # force_destroy defaults to false so an accidental destroy cannot silently
  # drop a bucket that still holds n8n binary-data attachments.
  assert {
    condition     = google_storage_bucket.n8n[0].force_destroy == false
    error_message = "gcs_force_destroy should default to false"
  }

  # Bucket name: <project_id>-n8n-<friendly_name_prefix>.
  assert {
    condition     = google_storage_bucket.n8n[0].name == "test-project-n8n-test"
    error_message = "GCS bucket name should be <project_id>-n8n-<friendly_name_prefix>"
  }

  assert {
    condition     = google_storage_bucket.n8n[0].versioning[0].enabled == true
    error_message = "GCS bucket must have object versioning enabled"
  }

  # Hard-block public grants regardless of IAM mistakes elsewhere.
  assert {
    condition     = google_storage_bucket.n8n[0].public_access_prevention == "enforced"
    error_message = "GCS bucket must enforce public access prevention"
  }

  # Versioning without a lifecycle rule grows without bound; the module must
  # ship a noncurrent-version cleanup rule alongside versioning.
  assert {
    condition     = length(google_storage_bucket.n8n[0].lifecycle_rule) == 1
    error_message = "GCS bucket must ship exactly one noncurrent-version cleanup lifecycle rule"
  }
}

# ── BYO HMAC input contract ──────────────────────────────────────────────────
# The BYO HMAC mode (gcs.tf) is guarded by cross-variable validations in
# variables_gcp.tf, they fail the plan (not just warn) so an incomplete BYO
# configuration can never apply with an empty S3 access key.

run "byo_hmac_missing_access_id_fails_validation" {
  command = plan

  variables {
    gcs_hmac_service_account_email = "byo-hmac@test-project.iam.gserviceaccount.com"
    gcs_hmac_secret_name           = "n8n-s3-external"
  }

  expect_failures = [var.gcs_hmac_access_id]
}

run "byo_hmac_missing_secret_fails_validation" {
  command = plan

  variables {
    gcs_hmac_service_account_email = "byo-hmac@test-project.iam.gserviceaccount.com"
    gcs_hmac_access_id             = "GOOG1EXAMPLEACCESSID"
  }

  # The "BYO needs a secret" rule lives on gcs_hmac_access_id (see
  # variables_gcp.tf for the acyclicity rationale).
  expect_failures = [var.gcs_hmac_access_id]
}

run "hmac_secret_name_without_byo_mode_fails_validation" {
  command = plan

  variables {
    gcs_hmac_secret_name = "n8n-s3-external"
  }

  expect_failures = [var.gcs_hmac_secret_name]
}

run "hmac_secret_without_byo_mode_fails_validation" {
  command = plan

  variables {
    gcs_hmac_secret = "not-a-real-secret"
  }

  expect_failures = [var.gcs_hmac_secret]
}

run "byo_hmac_complete_plans_cleanly" {
  command = plan

  variables {
    gcs_hmac_service_account_email = "byo-hmac@test-project.iam.gserviceaccount.com"
    gcs_hmac_access_id             = "GOOG1EXAMPLEACCESSID"
    gcs_hmac_secret_name           = "n8n-s3-external"
  }

  # In BYO mode the module skips SA/key creation and grants the supplied SA
  # access to the module-created bucket.
  assert {
    condition     = google_storage_bucket_iam_member.storage.member == "serviceAccount:byo-hmac@test-project.iam.gserviceaccount.com"
    error_message = "BYO mode must grant the caller-supplied service account access to the bucket"
  }
}

run "workload_identity_binds_correct_service_accounts" {
  command = plan

  assert {
    condition     = google_service_account.n8n.account_id == "test-n8n-wi"
    error_message = "n8n GSA account_id should be <friendly_name_prefix>-n8n-wi"
  }

  # The IAM binding lets the in-cluster KSA (namespace/n8n_kube_svc_account)
  # impersonate the Google service account via Workload Identity.
  assert {
    condition     = google_service_account_iam_member.n8n_workload_identity.member == "serviceAccount:test-project.svc.id.goog[n8n/n8n]"
    error_message = "workload identity member must be the project's KSA principal for namespace/SA"
  }

  assert {
    condition     = google_service_account_iam_member.n8n_workload_identity.role == "roles/iam.workloadIdentityUser"
    error_message = "workload identity binding must grant roles/iam.workloadIdentityUser"
  }
}

run "node_pool_uses_dedicated_service_account" {
  command = plan

  # Without a dedicated SA, nodes fall back to the project's default Compute
  # Engine SA (often Editor). node_config.service_account is the SA email,
  # which is unknown at plan time under the mock provider, so the wiring is
  # asserted at the SA + IAM level; verify the email wiring with a real
  # `terraform plan` from an example root.
  assert {
    condition     = google_service_account.nodes[0].account_id == "test-n8n-nodes"
    error_message = "node SA account_id should be <friendly_name_prefix>-n8n-nodes"
  }

  # The node SA holds exactly the minimal Google-recommended role set:
  # logging/monitoring pipelines plus Artifact Registry image pulls.
  assert {
    condition = alltrue([
      for role in [
        "roles/logging.logWriter",
        "roles/monitoring.metricWriter",
        "roles/monitoring.viewer",
        "roles/stackdriver.resourceMetadata.writer",
        "roles/artifactregistry.reader",
      ] : google_project_iam_member.nodes[role].role == role
    ])
    error_message = "node SA must hold the minimal logging/monitoring/artifact-registry role set"
  }
}

run "keda_installed" {
  command = plan

  # KEDA is installed by modules/controllers (controllers.tf), addressed here
  # through its outputs (terraform test cannot reach a child module's
  # internal resources directly); see modules/controllers/tests for the
  # submodule's own direct resource-level assertions.
  assert {
    condition     = module.controllers.keda_installed == true
    error_message = "KEDA helm release must exist - worker autoscaling depends on it"
  }

  assert {
    condition     = module.controllers.keda_namespace == "keda"
    error_message = "KEDA must be installed in its own 'keda' namespace"
  }

  # Pinned so applies are reproducible; keep in sync with the
  # keda_chart_version default in variables.tf.
  assert {
    condition     = module.controllers.keda_chart_version == "2.20.1"
    error_message = "KEDA chart version must be pinned to the keda_chart_version default"
  }
}

# The module ships an explicit balanced-PD StorageClass for any stateful
# workload a user runs beside n8n. It uses the GCE PD CSI driver and is
# intentionally NOT marked the cluster default (GKE's standard-rwo stays
# default), so it is purely additive.
run "pd_balanced_storage_class" {
  command = plan

  # Created by modules/controllers (controllers.tf), addressed here through
  # its output (terraform test cannot reach a child module's internal
  # resources directly); see modules/controllers/tests for the submodule's
  # own direct resource-level assertions covering provisioner, reclaim
  # policy, binding mode, expansion, and disk type.
  assert {
    condition     = module.controllers.pd_balanced_storage_class_name == "n8n-pd-balanced"
    error_message = "StorageClass must be named n8n-pd-balanced"
  }
}

run "custom_database_sizing" {
  command = plan

  variables {
    postgres_machine_type = "db-custom-8-30720"
    postgres_disk_size    = 200
    postgres_version      = "POSTGRES_15"
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].tier == "db-custom-8-30720"
    error_message = "postgres_machine_type variable did not propagate"
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].disk_size == 200
    error_message = "postgres_disk_size variable did not propagate"
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].database_version == "POSTGRES_15"
    error_message = "postgres_version variable did not propagate"
  }
}

run "custom_namespace_propagates_to_workload_identity" {
  command = plan

  variables {
    n8n_kube_namespace = "n8n-prod"
  }

  assert {
    condition     = google_service_account_iam_member.n8n_workload_identity.member == "serviceAccount:test-project.svc.id.goog[n8n-prod/n8n]"
    error_message = "workload identity member namespace should track var.n8n_kube_namespace"
  }
}

# ── Logging variables ────────────────────────────────────────────────────────
# N8N_LOG_OUTPUT was previously a hardcoded "json", which is not a valid value
# (it controls log destinations, not format). With an invalid value Winston
# attaches no transport and silently drops every log line. These tests pin the
# corrected defaults and the validators that prevent the regression. The Helm
# values blob itself is unknown at plan time under the helm mock provider, so
# we assert at the variable contract level - n8n.tf wires both vars through
# verbatim into the extraEnv list.

run "log_defaults" {
  command = plan

  assert {
    # Regression guard: the previous hardcoded value was "json". Anything other
    # than a console/file combination here breaks logging entirely.
    condition     = var.n8n_log_output == "console"
    error_message = "n8n_log_output must default to 'console' - 'json' (the previous value) silently drops all logs."
  }

  assert {
    condition     = var.n8n_log_level == "info"
    error_message = "n8n_log_level must default to 'info'."
  }
}

run "log_level_validator_rejects_invalid_value" {
  command = plan

  variables {
    n8n_log_level = "trace"
  }

  expect_failures = [var.n8n_log_level]
}

run "log_output_validator_rejects_json" {
  command = plan

  variables {
    # The original bug: "json" is not a valid N8N_LOG_OUTPUT value. The
    # validator must catch this at plan time so the regression cannot recur.
    n8n_log_output = "json"
  }

  expect_failures = [var.n8n_log_output]
}

run "log_output_accepts_console_and_file_combination" {
  command = plan

  variables {
    n8n_log_output = "console,file"
  }

  assert {
    condition     = var.n8n_log_output == "console,file"
    error_message = "n8n_log_output validator should accept comma-separated console,file."
  }
}

# ── Community packages ───────────────────────────────────────────────────────
# Both toggles map straight to n8n env vars and default to false so the env var
# is omitted (n8n's own default applies). The Helm values blob is unknown at
# plan time under the mock provider, so we assert at the variable contract
# level; that the entries land in config.extraEnv is verified by a real
# terraform plan from an example root.

run "community_package_toggles_default_false" {
  command = plan

  assert {
    condition     = var.n8n_reinstall_missing_packages == false
    error_message = "n8n_reinstall_missing_packages must default to false so n8n's own default applies."
  }

  assert {
    condition     = var.n8n_community_packages_prevent_loading == false
    error_message = "n8n_community_packages_prevent_loading must default to false so n8n's own default applies."
  }
}

run "community_package_toggles_accept_true" {
  command = plan

  variables {
    n8n_reinstall_missing_packages         = true
    n8n_community_packages_prevent_loading = true
  }

  assert {
    condition     = var.n8n_reinstall_missing_packages == true
    error_message = "n8n_reinstall_missing_packages should accept true."
  }

  assert {
    condition     = var.n8n_community_packages_prevent_loading == true
    error_message = "n8n_community_packages_prevent_loading should accept true."
  }
}

# ── OpenTelemetry tracing toggles ─────────────────────────────────────────────
# n8n_otel_enabled is the master switch (default false, contractually).
# Each tuning variable defaults to null so that, when n8n_otel_enabled is
# false, the whole config.extraEnv OTEL block collapses to []. The actual
# extraEnv list lives inside helm_release.n8n.values (a JSON-encoded string)
# and is awkward to inspect in plan-time tests; we assert at the variable
# contract layer, plus we keep a regression guard that the master toggle's
# default is false.

run "otel_defaults_off" {
  command = plan

  assert {
    condition     = var.n8n_otel_enabled == false
    error_message = "n8n_otel_enabled must default to false - OpenTelemetry tracing is opt-in."
  }

  assert {
    condition = (
      var.n8n_otel_exporter_otlp_endpoint == null &&
      var.n8n_otel_exporter_otlp_headers == null &&
      var.n8n_otel_exporter_service_name == null &&
      var.n8n_otel_traces_sample_rate == null &&
      var.n8n_otel_traces_include_node_spans == null &&
      var.n8n_otel_traces_inject_outbound == null &&
      var.n8n_otel_traces_production_only == null
    )
    error_message = "All n8n_otel_* tuning variables must default to null so an individual unset value falls back to n8n's own default."
  }
}

run "otel_sample_rate_validator_rejects_negative" {
  command = plan

  variables {
    n8n_otel_traces_sample_rate = -0.1
  }

  expect_failures = [var.n8n_otel_traces_sample_rate]
}

run "otel_sample_rate_validator_rejects_above_one" {
  command = plan

  variables {
    n8n_otel_traces_sample_rate = 1.5
  }

  expect_failures = [var.n8n_otel_traces_sample_rate]
}

run "otel_sample_rate_validator_accepts_zero_one_and_fractional" {
  command = plan

  variables {
    # Master toggle on so this run isn't tripped by the
    # `check "otel_tuning_requires_master_switch"` block in n8n.tf - the
    # purpose of this run is to exercise the sample-rate validator, not the
    # master/tuning interaction (which has its own runs below).
    n8n_otel_enabled            = true
    n8n_otel_traces_sample_rate = 0.25
  }

  assert {
    condition     = var.n8n_otel_traces_sample_rate == 0.25
    error_message = "n8n_otel_traces_sample_rate validator must accept fractional values in [0, 1]."
  }
}

run "otel_enabled_with_endpoint_propagates_through_variables" {
  command = plan

  variables {
    n8n_otel_enabled                = true
    n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318"
  }

  assert {
    condition = (
      var.n8n_otel_enabled == true &&
      var.n8n_otel_exporter_otlp_endpoint == "http://otel-collector.observability.svc.cluster.local:4318"
    )
    error_message = "Master toggle + endpoint variables must accept their typical opt-in values."
  }
}

# Regression guards for the `check "otel_tuning_requires_master_switch"`
# block in n8n.tf. Check blocks emit warnings on interactive plan/apply but
# are treated as failures by `terraform test`. We use that property:
# `expect_failures = [check.otel_tuning_requires_master_switch]` turns the
# warning-path test into an explicit "this check is supposed to fire here"
# assertion. If someone deletes the check block, this test fails (no
# failure to match the expectation), making the regression visible.
#
# The companion run `otel_tuning_set_with_master_on_plans_cleanly` covers
# the clean path (master on + tuning set, check happy) to make sure the
# check block also doesn't false-positive.

run "otel_tuning_set_with_master_off_triggers_check_warning" {
  command = plan

  variables {
    n8n_otel_enabled                = false
    n8n_otel_exporter_otlp_endpoint = "http://otel-collector.observability.svc.cluster.local:4318"
    n8n_otel_traces_sample_rate     = 0.1
  }

  expect_failures = [check.otel_tuning_requires_master_switch]
}

run "otel_tuning_set_with_master_on_plans_cleanly" {
  command = plan

  variables {
    n8n_otel_enabled                   = true
    n8n_otel_exporter_otlp_endpoint    = "http://otel-collector.observability.svc.cluster.local:4318"
    n8n_otel_exporter_service_name     = "n8n-prod"
    n8n_otel_traces_sample_rate        = 0.5
    n8n_otel_traces_include_node_spans = false
    n8n_otel_traces_inject_outbound    = true
  }

  assert {
    condition = (
      var.n8n_otel_enabled == true &&
      var.n8n_otel_exporter_otlp_endpoint != null &&
      var.n8n_otel_exporter_service_name == "n8n-prod" &&
      var.n8n_otel_traces_sample_rate == 0.5 &&
      var.n8n_otel_traces_include_node_spans == false &&
      var.n8n_otel_traces_inject_outbound == true
    )
    error_message = "Full opt-in path (master on + multiple tuning vars set) must remain plan-able."
  }
}

# ── n8n feature toggles (templates and personalization) ───────────────────────
# Both toggles default to true (feature enabled, no env var set). When disabled
# (false), they inject N8N_TEMPLATES_ENABLED=false or N8N_PERSONALIZATION_ENABLED=false.
# The Helm values blob is unknown at plan time under the mock provider, so we
# assert at the variable contract level; that the entries land in config.extraEnv
# is verified by a real terraform plan from an example root.

run "feature_toggles_default_enabled" {
  command = plan

  assert {
    condition     = var.n8n_templates_enabled == true
    error_message = "n8n_templates_enabled must default to true to preserve current behavior."
  }

  assert {
    condition     = var.n8n_personalization_enabled == true
    error_message = "n8n_personalization_enabled must default to true to preserve current behavior."
  }
}

run "feature_toggles_accept_false" {
  command = plan

  variables {
    n8n_templates_enabled       = false
    n8n_personalization_enabled = false
  }

  assert {
    condition     = var.n8n_templates_enabled == false
    error_message = "n8n_templates_enabled should accept false to disable workflow templates."
  }

  assert {
    condition     = var.n8n_personalization_enabled == false
    error_message = "n8n_personalization_enabled should accept false to disable personalization."
  }
}

# ── Log streaming (Enterprise, managed via env vars) ──────────────────────────
# n8n_log_streaming_managed_by_env is the master switch (default false). The
# destinations list is typed `any` (webhook/syslog/sentry shapes differ) and is
# JSON-encoded into N8N_LOG_STREAMING_DESTINATIONS only when the master switch
# is on. The Helm values blob is unknown at plan time under the mock provider,
# so we assert at the variable contract level; the wiring into config.extraEnv
# is verified by a real terraform plan.

run "log_streaming_defaults_off" {
  command = plan

  assert {
    condition     = var.n8n_log_streaming_managed_by_env == false
    error_message = "n8n_log_streaming_managed_by_env must default to false - env-managed log streaming is opt-in."
  }

  assert {
    condition     = length(var.n8n_log_streaming_destinations) == 0
    error_message = "n8n_log_streaming_destinations must default to an empty list."
  }
}

run "log_streaming_rejects_invalid_destination_type" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = true
    n8n_log_streaming_destinations = [
      { type = "kafka", label = "not-a-real-destination" },
    ]
  }

  expect_failures = [var.n8n_log_streaming_destinations]
}

run "log_streaming_rejects_string_instead_of_list" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = true
    n8n_log_streaming_destinations   = "[{\"type\":\"webhook\"}]"
  }

  expect_failures = [var.n8n_log_streaming_destinations]
}

run "log_streaming_accepts_mixed_destinations" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = true
    n8n_log_streaming_destinations = [
      {
        type             = "webhook"
        label            = "Audit"
        enabled          = true
        subscribedEvents = ["n8n.audit", "n8n.workflow"]
        url              = "https://hooks.example.com/n8n"
        method           = "POST"
      },
      {
        type  = "syslog"
        label = "SIEM"
      },
    ]
  }

  assert {
    condition     = length(var.n8n_log_streaming_destinations) == 2
    error_message = "n8n_log_streaming_destinations should accept a heterogeneous list of webhook/syslog/sentry objects."
  }
}

run "log_streaming_destinations_with_master_off_triggers_check_warning" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = false
    n8n_log_streaming_destinations = [
      { type = "webhook", url = "https://hooks.example.com/n8n" },
    ]
  }

  expect_failures = [check.log_streaming_destinations_require_managed_by_env]
}

run "log_streaming_full_opt_in_plans_cleanly" {
  command = plan

  variables {
    n8n_log_streaming_managed_by_env = true
    n8n_log_streaming_destinations = [
      { type = "sentry", label = "Errors" },
    ]
  }

  assert {
    condition     = var.n8n_log_streaming_managed_by_env == true
    error_message = "Full opt-in path (master on + destinations set) must remain plan-able."
  }
}

# ── n8n_extra_env ────────────────────────────────────────────────────────────
# Asserted at the variable-contract level: defaults, accepted shape, and the
# validation guards (non-empty name, no duplicates, no collision with
# module-managed env vars). End-to-end wiring into config.extraEnv can't be
# checked here: helm_release.values depends on kubernetes_namespace (unknown at
# plan time). Verify the wiring with a real terraform plan.

run "extra_env_defaults_to_empty" {
  command = plan

  assert {
    condition     = length(var.n8n_extra_env) == 0
    error_message = "n8n_extra_env must default to an empty list."
  }
}

run "extra_env_accepts_valid_entries" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_DEFAULT_LOCALE", value = "de" },
      { name = "N8N_PAYLOAD_SIZE_MAX", value = "32" },
    ]
  }

  assert {
    condition     = length(var.n8n_extra_env) == 2
    error_message = "n8n_extra_env should accept a list of {name, value} objects."
  }

  assert {
    condition     = var.n8n_extra_env[0].name == "N8N_DEFAULT_LOCALE"
    error_message = "n8n_extra_env entry name should propagate correctly."
  }

  assert {
    condition     = var.n8n_extra_env[0].value == "de"
    error_message = "n8n_extra_env entry value should propagate correctly."
  }
}

run "extra_env_rejects_empty_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "", value = "x" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# Whitespace-padded names must be rejected: otherwise a name like " DB_HOST"
# would pass the duplicate and module-managed guards (which match on the raw
# string) while Kubernetes renders it as a distinct, ignored env var.
run "extra_env_rejects_whitespace_padded_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = " DB_POSTGRESDB_HOST", value = "evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_duplicate_names" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_DEFAULT_LOCALE", value = "de" },
      { name = "N8N_DEFAULT_LOCALE", value = "en" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_module_managed_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_LOG_LEVEL", value = "debug" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# Regression guards: env vars the module started managing after this input was
# first written (templates/personalization, OTEL, log streaming) must also be
# rejected by the escape hatch - keep local.n8n_managed_env_names in sync.
run "extra_env_rejects_feature_toggle_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_PERSONALIZATION_ENABLED", value = "false" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_otel_managed_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_OTEL_ENABLED", value = "false" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_log_streaming_managed_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_LOG_STREAMING_MANAGED_BY_ENV", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# Prefix-family guards: connection and license vars the chart renders from
# module values must be rejected, because config.extraEnv is appended last and
# Kubernetes resolves duplicate env names last-wins - an override here would
# silently repoint the DB, the Redis queue, or disable Enterprise.
run "extra_env_rejects_db_connection_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_POSTGRESDB_HOST", value = "evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_queue_connection_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "QUEUE_BULL_REDIS_HOST", value = "evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_license_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_LICENSE_ACTIVATION_KEY", value = "stolen-key" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# A genuinely non-managed var that happens to be timezone-related stays allowed:
# the chart sets TZ (blocked) but not GENERIC_TIMEZONE, so callers can set it.
run "extra_env_accepts_generic_timezone" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "GENERIC_TIMEZONE", value = "Europe/Berlin" },
    ]
  }

  assert {
    condition     = var.n8n_extra_env[0].name == "GENERIC_TIMEZONE"
    error_message = "GENERIC_TIMEZONE is not module-managed and should be accepted."
  }
}

run "image_tag_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_tag == null
    error_message = "n8n_image_tag should default to null so the chart's own stable tag applies by default."
  }
}

run "image_tag_accepts_concrete_version" {
  command = plan

  # Asserts at the variable contract level only - helm_release.values is
  # unknown at plan time under the mock provider (it depends on
  # kubernetes_namespace, which is "(known after apply)"), so the merge()
  # wiring of image.tag into the Helm values cannot be verified here.
  # To verify end-to-end: run `terraform plan` from examples/small/ with
  # n8n_image_tag = "2.27.4" and confirm `image.tag` appears in the
  # helm_release.n8n plan output.
  variables {
    n8n_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_image_tag == "2.27.4"
    error_message = "n8n_image_tag should accept a concrete version string."
  }
}

run "image_tag_rejects_empty_string" {
  command = plan

  variables {
    n8n_image_tag = ""
  }

  expect_failures = [var.n8n_image_tag]
}

run "image_tag_rejects_whitespace_padded_value" {
  command = plan

  variables {
    n8n_image_tag = " 1.2.3 "
  }

  expect_failures = [var.n8n_image_tag]
}

run "image_tag_accepts_leading_underscore" {
  command = plan

  variables {
    n8n_image_tag = "_1.2.3"
  }

  assert {
    condition     = var.n8n_image_tag == "_1.2.3"
    error_message = "n8n_image_tag should accept a leading underscore - valid per Docker tag spec."
  }
}

run "image_tag_rejects_overlong_tag" {
  command = plan

  variables {
    # 129 characters - one over the Docker limit of 128
    n8n_image_tag = "a${join("", [for i in range(128) : "b"])}"
  }

  expect_failures = [var.n8n_image_tag]
}

# ── friendly_name_prefix naming contract ──────────────────────────────────────
# GCP resource names are RFC1035 (lowercase letter start, lowercase
# alphanumerics and hyphens, no trailing hyphen). The validator fails these at
# plan time instead of letting the first apply die on the VPC or cluster name.

run "friendly_name_prefix_rejects_uppercase" {
  command = plan

  variables {
    friendly_name_prefix = "Prod"
  }

  expect_failures = [var.friendly_name_prefix]
}

run "friendly_name_prefix_rejects_trailing_hyphen" {
  command = plan

  variables {
    friendly_name_prefix = "prod-"
  }

  expect_failures = [var.friendly_name_prefix]
}

run "friendly_name_prefix_rejects_leading_digit" {
  command = plan

  variables {
    friendly_name_prefix = "8prod"
  }

  expect_failures = [var.friendly_name_prefix]
}

run "friendly_name_prefix_rejects_n8n_substring" {
  command = plan

  variables {
    friendly_name_prefix = "myn8ncluster"
  }

  expect_failures = [var.friendly_name_prefix]
}

run "friendly_name_prefix_rejects_overlong_value" {
  command = plan

  variables {
    # 21 characters - one over the 20-char cap (SA account_id limit).
    friendly_name_prefix = join("", [for i in range(21) : "a"])
  }

  expect_failures = [var.friendly_name_prefix]
}

run "common_labels_merge_into_resource_labels" {
  command = plan

  variables {
    common_labels = {
      team = "platform"
      env  = "staging"
    }
  }

  assert {
    condition = (
      google_container_cluster.n8n[0].resource_labels["team"] == "platform" &&
      google_container_cluster.n8n[0].resource_labels["env"] == "staging"
    )
    error_message = "common_labels entries must be merged into resource_labels"
  }

  assert {
    condition     = google_container_cluster.n8n[0].resource_labels["managed_by"] == "terraform"
    error_message = "common_labels must not override the module's built-in labels"
  }
}

# ── Valid scaling inputs (main-topology: replicas, worker concurrency, ────────
# scaler thresholds, GKE per-zone bounds, boot-disk size) ─────────────────────
# Every one of these variables is now non-null, whole-number, and (where an
# upper/lower pair exists) ordered; see variables.tf / variables_gcp.tf for the
# validation blocks. These tests exercise the negative/fractional/reversed
# cases each validation exists to reject, plus one representative valid case
# per variable to confirm the default/documented values still plan cleanly.

run "worker_concurrency_rejects_fractional" {
  command = plan

  variables {
    n8n_worker_concurrency = 2.5
  }

  expect_failures = [var.n8n_worker_concurrency]
}

run "worker_concurrency_rejects_zero" {
  command = plan

  variables {
    n8n_worker_concurrency = 0
  }

  expect_failures = [var.n8n_worker_concurrency]
}

run "main_hpa_replicas_reject_fractional_bounds" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1.5
  }

  expect_failures = [var.n8n_main_hpa_min_replicas]
}

run "main_hpa_replicas_reject_reversed_bounds" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 5
    n8n_main_hpa_max_replicas = 2
  }

  expect_failures = [var.n8n_main_hpa_max_replicas]
}

run "main_hpa_cpu_threshold_rejects_out_of_range" {
  command = plan

  variables {
    n8n_main_hpa_cpu_threshold = 150
  }

  expect_failures = [var.n8n_main_hpa_cpu_threshold]
}

run "webhook_hpa_replicas_reject_reversed_bounds" {
  command = plan

  variables {
    n8n_webhook_hpa_min_replicas = 10
    n8n_webhook_hpa_max_replicas = 3
  }

  expect_failures = [var.n8n_webhook_hpa_max_replicas]
}

run "webhook_hpa_cpu_threshold_rejects_zero" {
  command = plan

  variables {
    n8n_webhook_hpa_cpu_threshold = 0
  }

  expect_failures = [var.n8n_webhook_hpa_cpu_threshold]
}

run "worker_keda_replicas_reject_reversed_bounds" {
  command = plan

  variables {
    n8n_worker_keda_min_replicas = 8
    n8n_worker_keda_max_replicas = 1
  }

  expect_failures = [var.n8n_worker_keda_max_replicas]
}

run "worker_keda_jobs_per_replica_rejects_zero" {
  command = plan

  variables {
    n8n_worker_keda_jobs_per_replica = 0
  }

  expect_failures = [var.n8n_worker_keda_jobs_per_replica]
}

run "gke_node_per_zone_bounds_reject_fractional" {
  command = plan

  variables {
    gke_node_min_per_zone = 1.2
  }

  expect_failures = [var.gke_node_min_per_zone]
}

run "gke_node_per_zone_bounds_reject_reversed" {
  command = plan

  variables {
    gke_node_min_per_zone = 3
    gke_node_max_per_zone = 1
  }

  expect_failures = [var.gke_node_max_per_zone]
}

run "gke_node_disk_size_rejects_below_google_minimum" {
  command = plan

  variables {
    gke_node_disk_size_gb = 5
  }

  expect_failures = [var.gke_node_disk_size_gb]
}

run "gke_node_disk_size_rejects_fractional" {
  command = plan

  variables {
    gke_node_disk_size_gb = 100.5
  }

  expect_failures = [var.gke_node_disk_size_gb]
}

run "gke_node_disk_size_accepts_google_minimum" {
  command = plan

  variables {
    gke_node_disk_size_gb = 10
  }

  assert {
    condition     = google_container_node_pool.n8n[0].node_config[0].disk_size_gb == 10
    error_message = "gke_node_disk_size_gb=10 (Google's documented minimum) must be accepted and wired through unchanged."
  }
}

# ── CPU/memory quantity grammar (capacity-guardrails) ─────────────────────────
# Every *_cpu_request/limit and *_memory_request/limit variable across main,
# worker, webhook, and task-runner roles now validates against exactly the
# grammar capacity.tf's parser supports, so an unparsable quantity fails at
# variable validation instead of a tonumber()/endswith() expression error deep
# in a local. One representative valid and one invalid case per quantity shape
# (bare-core/millicore CPU, bare-byte/Ki/Mi/Gi memory) is enough to prove the
# regex, since every role's variable shares the identical pattern.

run "cpu_quantities_accept_bare_core_and_millicore_forms" {
  command = plan

  variables {
    n8n_main_cpu_request        = "0.5"
    n8n_worker_cpu_limit        = "1500m"
    n8n_task_runner_cpu_request = "1"
  }

  assert {
    condition     = var.n8n_main_cpu_request == "0.5" && var.n8n_worker_cpu_limit == "1500m" && var.n8n_task_runner_cpu_request == "1"
    error_message = "Bare-core and millicore CPU quantities must be accepted."
  }
}

run "cpu_quantity_rejects_unsupported_suffix" {
  command = plan

  variables {
    n8n_main_cpu_request = "500mCPU"
  }

  expect_failures = [var.n8n_main_cpu_request]
}

run "cpu_quantity_rejects_non_numeric_value" {
  command = plan

  variables {
    n8n_worker_cpu_limit = "2vCPU"
  }

  expect_failures = [var.n8n_worker_cpu_limit]
}

run "memory_quantities_accept_ki_mi_gi_and_bare_byte_forms" {
  command = plan

  variables {
    n8n_main_memory_limit          = "4Gi"
    n8n_worker_memory_request      = "512Mi"
    n8n_webhook_memory_limit       = "1024Ki"
    n8n_task_runner_memory_request = "268435456"
  }

  assert {
    condition = (
      var.n8n_main_memory_limit == "4Gi" &&
      var.n8n_worker_memory_request == "512Mi" &&
      var.n8n_webhook_memory_limit == "1024Ki" &&
      var.n8n_task_runner_memory_request == "268435456"
    )
    error_message = "Gi/Mi/Ki-suffixed and bare-byte memory quantities must be accepted."
  }
}

run "memory_quantity_rejects_unsupported_suffix" {
  command = plan

  variables {
    n8n_main_memory_request = "1Ti"
  }

  expect_failures = [var.n8n_main_memory_request]
}

run "memory_quantity_rejects_non_numeric_value" {
  command = plan

  variables {
    n8n_webhook_memory_request = "half-a-gig"
  }

  expect_failures = [var.n8n_webhook_memory_request]
}

# ── Webhook HPA scale-up stabilization window (main-topology) ────────────────

run "webhook_hpa_stabilization_defaults_to_zero_and_omits_behavior" {
  command = plan

  assert {
    condition     = var.n8n_webhook_hpa_scale_up_stabilization_window_seconds == 0
    error_message = "n8n_webhook_hpa_scale_up_stabilization_window_seconds must default to 0."
  }

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].behavior) == 0
    error_message = "At the default (0), no behavior block should be rendered on the webhook HPA."
  }
}

run "webhook_hpa_stabilization_explicit_60_renders_behavior" {
  command = plan

  variables {
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 60
  }

  assert {
    condition     = kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook[0].spec[0].behavior[0].scale_up[0].stabilization_window_seconds == 60
    error_message = "n8n_webhook_hpa_scale_up_stabilization_window_seconds=60 must be wired into the HPA's scale_up.stabilization_window_seconds."
  }
}

run "webhook_hpa_stabilization_rejects_out_of_bounds" {
  command = plan

  variables {
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 3601
  }

  expect_failures = [var.n8n_webhook_hpa_scale_up_stabilization_window_seconds]
}

run "webhook_hpa_stabilization_rejects_negative" {
  command = plan

  variables {
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = -1
  }

  expect_failures = [var.n8n_webhook_hpa_scale_up_stabilization_window_seconds]
}

run "webhook_hpa_stabilization_has_no_effect_when_hpa_disabled" {
  command = plan

  variables {
    n8n_webhook_hpa_enabled                               = false
    n8n_webhook_hpa_scale_up_stabilization_window_seconds = 60
  }

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 0
    error_message = "No webhook HPA (and so no behavior/stabilization setting) should be rendered when n8n_webhook_hpa_enabled = false, regardless of the stabilization value."
  }
}

# ── Worker pools (EARLY ALPHA) ────────────────────────────────────────────────
# Asserted at the variable-contract level, plus the chart-pairing precondition
# on helm_release.n8n (which is a real Terraform precondition, so a mocked
# `plan` does exercise it). queueMode.workerGroups wiring inside
# helm_release.values can't be asserted here (values is unknown at plan time
# under the mock provider, same limitation as n8n_extra_env above).

run "worker_pools_default_to_empty" {
  command = plan

  assert {
    condition     = length(var.n8n_worker_pools) == 0
    error_message = "n8n_worker_pools must default to an empty list."
  }

  assert {
    condition     = length(var.n8n_worker_extra_env) == 0
    error_message = "n8n_worker_extra_env must default to an empty list."
  }
}

run "worker_pools_with_prerelease_chart_plans_cleanly" {
  command = plan

  # A prerelease version is taken at the caller's word (the hyphen check in
  # local.n8n_chart_renders_worker_pools), so the precondition passes without
  # n8n_worker_pools_chart_verified.
  variables {
    n8n_chart_version = "1.11.0-preview.workerpools.1"
    n8n_worker_pools = [
      { name = "heavy", min_replicas = 1, max_replicas = 4, concurrency = 5 },
    ]
  }

  assert {
    condition     = length(var.n8n_worker_pools) == 1
    error_message = "n8n_worker_pools should accept a minimal pool entry."
  }

  assert {
    condition     = var.n8n_worker_pools[0].name == "heavy"
    error_message = "n8n_worker_pools name should propagate correctly."
  }
}

run "worker_pools_with_numbered_chart_fails_precondition" {
  command = plan

  # The default n8n_chart_version (a numbered release) cannot be trusted to
  # render queueMode.workerGroups, and n8n_worker_pools_chart_verified is not
  # set, so helm_release.n8n's precondition must fail the plan rather than
  # apply cleanly with the pools silently unrendered.
  variables {
    n8n_worker_pools = [
      { name = "heavy" },
    ]
  }

  expect_failures = [helm_release.n8n]
}

run "worker_pools_with_numbered_chart_and_verified_attestation_plans_cleanly" {
  command = plan

  variables {
    n8n_worker_pools = [
      { name = "heavy" },
    ]
    n8n_worker_pools_chart_verified = true
  }

  assert {
    condition     = var.n8n_worker_pools_chart_verified == true
    error_message = "n8n_worker_pools_chart_verified should accept true."
  }
}

run "worker_pools_reject_default_name" {
  command = plan

  variables {
    n8n_worker_pools = [
      { name = "default" },
    ]
  }

  expect_failures = [var.n8n_worker_pools]
}

run "worker_pools_reject_uppercase_name" {
  command = plan

  variables {
    n8n_worker_pools = [
      { name = "ITop" },
    ]
  }

  expect_failures = [var.n8n_worker_pools]
}

run "worker_pools_reject_duplicate_names" {
  command = plan

  variables {
    n8n_worker_pools = [
      { name = "heavy" },
      { name = "heavy" },
    ]
  }

  expect_failures = [var.n8n_worker_pools]
}

run "worker_pools_reject_reversed_replica_bounds" {
  command = plan

  variables {
    n8n_worker_pools = [
      { name = "heavy", min_replicas = 5, max_replicas = 1 },
    ]
  }

  expect_failures = [var.n8n_worker_pools]
}

run "worker_pools_accept_scale_to_zero" {
  command = plan

  variables {
    n8n_chart_version = "1.11.0-preview.workerpools.1"
    n8n_worker_pools = [
      { name = "itop", min_replicas = 0, max_replicas = 3 },
    ]
  }

  assert {
    condition     = var.n8n_worker_pools[0].min_replicas == 0
    error_message = "n8n_worker_pools min_replicas must accept 0 for scale-to-zero pools."
  }
}

run "worker_pools_reject_pool_name_env_override" {
  command = plan

  variables {
    n8n_worker_pools = [
      {
        name = "heavy"
        extra_env = [
          { name = "N8N_WORKER_POOL_NAME", value = "other" },
        ]
      },
    ]
  }

  expect_failures = [var.n8n_worker_pools]
}

run "worker_pools_reject_unsupported_cpu_quantity" {
  command = plan

  variables {
    n8n_worker_pools = [
      { name = "heavy", cpu_request = "1 core" },
    ]
  }

  expect_failures = [var.n8n_worker_pools]
}

run "worker_extra_env_rejects_pool_name_var" {
  command = plan

  variables {
    n8n_worker_extra_env = [
      { name = "N8N_WORKER_POOL_NAME", value = "heavy" },
    ]
  }

  expect_failures = [var.n8n_worker_extra_env]
}

run "worker_pools_old_image_tag_triggers_check_warning" {
  command = plan

  # check.worker_pools_require_n8n_2_39 warns (not a hard failure) when an
  # image predating worker pools is pinned alongside a non-empty
  # n8n_worker_pools. Listed in expect_failures because a triggered `check`
  # block counts as a failure for terraform test even though it does not
  # block the plan.
  variables {
    n8n_chart_version = "1.11.0-preview.workerpools.1"
    n8n_image_tag     = "2.38.7"
    n8n_worker_pools = [
      { name = "heavy" },
    ]
  }

  expect_failures = [check.worker_pools_require_n8n_2_39]
}

run "worker_pools_new_image_tag_plans_cleanly" {
  command = plan

  variables {
    n8n_chart_version = "1.11.0-preview.workerpools.1"
    n8n_image_tag     = "2.39.0"
    n8n_worker_pools = [
      { name = "heavy" },
    ]
  }

  assert {
    condition     = var.n8n_image_tag == "2.39.0"
    error_message = "n8n_image_tag should accept a version at the worker pools floor."
  }
}

run "worker_pools_with_managed_redis_tls_ca_trigger_check_warning" {
  command = plan

  # check.worker_pools_with_managed_redis_tls_ca (worker-pools.tf) warns when
  # pools are combined with module-managed Memorystore transit encryption,
  # whose private CA a pool's metadata-only KEDA trigger cannot trust.
  variables {
    n8n_chart_version                = "1.11.0-preview.workerpools.1"
    redis_transit_encryption_enabled = true
    n8n_worker_pools = [
      { name = "heavy" },
    ]
  }

  expect_failures = [check.worker_pools_with_managed_redis_tls_ca]
}

run "worker_pools_with_external_tls_redis_plans_cleanly" {
  command = plan

  # External TLS Redis has no module-managed CA, so the check stays quiet and
  # the pool metadata carries enableTLS the same way the default worker does.
  variables {
    n8n_chart_version     = "1.11.0-preview.workerpools.1"
    create_redis_instance = false
    redis_host            = "redis.example.internal"
    redis_tls_enabled     = true
    n8n_worker_pools = [
      { name = "heavy" },
    ]
  }

  assert {
    condition     = try(local.n8n_worker_pool_keda_metadata.enableTLS, null) == "true"
    error_message = "pool trigger metadata must carry enableTLS=\"true\" against an external TLS Redis, matching the default worker's trigger rule."
  }
}
