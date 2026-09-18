# Plan-time tests for the section 6 Redis ownership and connection contract:
# count-gating Memorystore (create_redis_instance), the external host/port/TLS/
# ACL-username/password (direct or existing-Secret) contract, managed
# BASIC/STANDARD_HA/AUTH/transit-encryption combinations, the Cloud KMS
# create-or-reference contract, redis_key_prefix synchronization with KEDA, and
# the STANDARD_HA failover-timeout validation.

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

# ── Defaults create every managed Redis resource ──────────────────────────────

run "defaults_create_managed_redis_resources" {
  command = plan

  assert {
    condition     = length(google_redis_instance.n8n) == 1
    error_message = "create_redis_instance defaults to true and must create the Memorystore instance."
  }

  assert {
    condition     = length(kubernetes_secret.redis_auth) == 0
    error_message = "redis_auth_enabled defaults to false; no AUTH Secret should be created."
  }

  assert {
    condition     = length(kubectl_manifest.redis_trigger_auth) == 0
    error_message = "No password is present by default (AUTH disabled); no TriggerAuthentication should be created."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "The external-password Secret must not be created for the module-managed instance."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis_username) == 0
    error_message = "No username Secret should be created for the module-managed instance."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis_tls) == 0
    error_message = "Transit encryption defaults to false; no Redis CA Secret should be created."
  }

  assert {
    condition     = output.redis_username == null
    error_message = "redis_username output must be null for module-managed Memorystore."
  }

  assert {
    condition     = output.redis_kms_key_id == null
    error_message = "redis_kms_key_id output must be null when no KMS key is configured."
  }
}

# ── Managed AUTH wires the generated AUTH string into a shared Secret ────────

run "managed_redis_auth_wires_trigger_authentication" {
  command = plan

  variables {
    redis_auth_enabled = true
  }

  assert {
    condition     = length(kubernetes_secret.redis_auth) == 1
    error_message = "redis_auth_enabled = true must create the AUTH Secret."
  }

  assert {
    condition     = length(kubectl_manifest.redis_trigger_auth) == 1
    error_message = "A password is present (managed AUTH); KEDA must get a TriggerAuthentication."
  }
}

# ── Managed STANDARD_HA and transit encryption ───────────────────────────────

run "managed_redis_standard_ha_and_transit_encryption" {
  command = plan

  variables {
    redis_tier                       = "STANDARD_HA"
    redis_transit_encryption_enabled = true
    n8n_redis_timeout_threshold_ms   = 30000
  }

  assert {
    condition     = google_redis_instance.n8n[0].tier == "STANDARD_HA"
    error_message = "redis_tier must propagate to the managed instance."
  }

  assert {
    condition     = google_redis_instance.n8n[0].transit_encryption_mode == "SERVER_AUTHENTICATION"
    error_message = "redis_transit_encryption_enabled = true must set transit_encryption_mode to SERVER_AUTHENTICATION."
  }

  assert {
    condition     = output.redis_tls_enabled == true
    error_message = "redis_tls_enabled output must reflect redis_transit_encryption_enabled for the managed instance."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis_tls) == 1
    error_message = "Managed Redis transit encryption must create the CA Secret consumed by n8n and KEDA."
  }

  assert {
    condition     = length(kubectl_manifest.redis_trigger_auth) == 1
    error_message = "Managed Redis transit encryption must create a TriggerAuthentication for KEDA CA trust even without AUTH."
  }
}

run "redis_tier_rejects_invalid_value" {
  command = plan

  variables {
    redis_tier = "PREMIUM"
  }

  expect_failures = [var.redis_tier]
}

run "standard_ha_requires_timeout_threshold_at_least_failover_window" {
  command = plan

  variables {
    redis_tier                     = "STANDARD_HA"
    n8n_redis_timeout_threshold_ms = 10000
  }

  expect_failures = [var.n8n_redis_timeout_threshold_ms]
}

# ── External Redis with a direct password creates no Memorystore resources ──

run "external_redis_direct_password_creates_no_memorystore_resources" {
  command = plan

  variables {
    create_redis_instance = false
    redis_host            = "10.9.8.8"
    redis_port            = 6380
    redis_tls_enabled     = true
    redis_username        = "n8n"
    redis_password        = "external-redis-password"
  }

  assert {
    condition     = length(google_redis_instance.n8n) == 0
    error_message = "create_redis_instance = false must not create a Memorystore instance."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 1
    error_message = "A direct external password must be wrapped in the module-managed Secret."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis_username) == 1
    error_message = "An external ACL username must be wrapped in a Secret for KEDA."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis_tls) == 0
    error_message = "External Redis TLS must not create a Secret from the module-managed Memorystore CA."
  }

  assert {
    condition     = length(kubectl_manifest.redis_trigger_auth) == 1
    error_message = "An external password must produce a KEDA TriggerAuthentication."
  }

  assert {
    condition     = output.redis_host == "10.9.8.8"
    error_message = "redis_host output must resolve to the supplied external host."
  }

  assert {
    condition     = output.redis_username == "n8n"
    error_message = "redis_username output must resolve to the supplied external username."
  }

  assert {
    condition     = output.redis_kms_key_id == null
    error_message = "redis_kms_key_id must be null for external Redis."
  }
}

# ── External Redis with an existing Secret reference creates no Secret ──────

run "external_redis_secret_reference_creates_no_managed_secret" {
  command = plan

  variables {
    create_redis_instance = false
    redis_host            = "10.9.8.8"
    redis_password_secret_ref = {
      name = "external-redis-credentials"
      key  = "redis-password"
    }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "An existing Secret reference must not create the module-managed password Secret."
  }

  assert {
    condition     = length(kubectl_manifest.redis_trigger_auth) == 1
    error_message = "An existing Secret reference still supplies a password; KEDA must still get a TriggerAuthentication."
  }
}

# ── External Redis without any password creates no password plumbing ────────

run "external_redis_without_password_creates_no_password_plumbing" {
  command = plan

  variables {
    create_redis_instance = false
    redis_host            = "10.9.8.8"
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "No password source is set; no password Secret should be created."
  }

  assert {
    condition     = length(kubectl_manifest.redis_trigger_auth) == 0
    error_message = "No password source is set; KEDA must not get a TriggerAuthentication."
  }
}

# ── Password source mutual exclusivity ───────────────────────────────────────

run "external_redis_both_password_sources_fails_validation" {
  command = plan

  variables {
    create_redis_instance = false
    redis_host            = "10.9.8.8"
    redis_password        = "external-redis-password"
    redis_password_secret_ref = {
      name = "external-redis-credentials"
    }
  }

  expect_failures = [var.redis_password_secret_ref]
}

# ── Opposite-path diagnostics ─────────────────────────────────────────────────

run "redis_external_settings_ignored_when_managed_triggers_warning" {
  command = plan

  variables {
    redis_host = "should-be-ignored"
  }

  expect_failures = [check.redis_external_settings_ignored_when_managed]
}

run "redis_kms_ignored_when_external_triggers_warning" {
  command = plan

  variables {
    create_redis_instance = false
    redis_host            = "10.9.8.8"
    create_redis_kms_key  = true
    create_kms_key_ring   = true
  }

  expect_failures = [check.redis_kms_ignored_when_external]

  assert {
    condition = (
      length(google_kms_key_ring.n8n) == 0 &&
      length(google_kms_crypto_key.redis) == 0 &&
      length(google_kms_crypto_key_iam_member.redis) == 0
    )
    error_message = "Ignored Redis CMEK inputs must not create a key ring, key, or IAM binding for an external Redis service."
  }
}

# ── redis_key_prefix synchronization with KEDA ────────────────────────────────

# helm_release.n8n's values are unknown at plan time under the mock provider
# (the resource depends on kubernetes_namespace, whose attributes are unknown;
# see AGENTS.md's "Known mock provider limitations"), so the KEDA trigger
# listName/n8n redis.prefix wiring itself cannot be asserted here. This only
# proves redis_key_prefix plans cleanly; verify the rendered Helm values (both
# redis.prefix and keda.worker.triggers[*].metadata.listName use "myprefix")
# with a real `terraform plan`/`helm template` from an example root.
run "redis_key_prefix_plans_cleanly" {
  command = plan

  variables {
    redis_key_prefix = "myprefix"
  }
}

run "redis_key_prefix_rejects_malformed_value" {
  command = plan

  variables {
    redis_key_prefix = "bad prefix:with colon"
  }

  expect_failures = [var.redis_key_prefix]
}

# ── N8N_REDIS_KEY_PREFIX command-channel prefix (task 7.1) ───────────────────

# Default (null) omits both the command-channel override (N8N_REDIS_KEY_PREFIX)
# and the Bull-prefix override (redis.prefix, asserted as "" above via the
# existing chart-truthiness comment in n8n.tf), so n8n keeps its own distinct
# "n8n" command-channel and "bull" Bull-queue defaults. helm_release.n8n's
# values are unknown at plan time under the mock provider (see AGENTS.md), so
# this only proves the default plans cleanly; the actual env-var omission is
# covered by tests/scripts/check-n8n-chart.sh.
run "redis_key_prefix_null_plans_cleanly" {
  command = plan
}

# A caller-supplied n8n_extra_env entry named N8N_REDIS_KEY_PREFIX must be
# rejected: config.extraEnv is appended last (Kubernetes last-wins) and would
# otherwise silently override the module's own N8N_REDIS_KEY_PREFIX value
# whenever redis_key_prefix is set.
run "extra_env_rejects_n8n_redis_key_prefix_name" {
  command = plan

  variables {
    redis_key_prefix = "myprefix"
    n8n_extra_env = [
      { name = "N8N_REDIS_KEY_PREFIX", value = "other" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# Two independent configurations against the same external Redis endpoint
# with different prefixes must plan cleanly on their own; the distinct
# command-prefix, Bull-prefix, and queue-key coordinates each configuration
# produces are asserted against the real rendered chart values in
# tests/scripts/check-n8n-chart.sh (helm_release.n8n's values are unknown at
# plan time under the mock provider, see AGENTS.md).
run "redis_key_prefix_deployment_a_plans_cleanly" {
  command = plan

  variables {
    create_redis_instance = false
    redis_host            = "shared-redis.internal"
    redis_key_prefix      = "deploy-a"
  }
}

run "redis_key_prefix_deployment_b_plans_cleanly" {
  command = plan

  variables {
    create_redis_instance = false
    redis_host            = "shared-redis.internal"
    redis_key_prefix      = "deploy-b"
  }
}

# ── Cloud KMS create-or-reference ─────────────────────────────────────────────

run "module_created_redis_key_wires_key_ring_and_iam" {
  command = plan

  variables {
    create_kms_key_ring  = true
    create_redis_kms_key = true
  }

  assert {
    condition     = length(google_kms_key_ring.n8n) == 1
    error_message = "create_kms_key_ring = true must create the shared key ring."
  }

  assert {
    condition     = length(google_kms_crypto_key.redis) == 1
    error_message = "create_redis_kms_key = true must create the Memorystore CryptoKey."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.redis) == 1
    error_message = "A module-created key must grant the Memorystore service agent IAM."
  }

  assert {
    condition = (
      length(google_project_service_identity.redis) == 1 &&
      google_project_service_identity.redis[0].project == "test-project" &&
      google_project_service_identity.redis[0].service == "redis.googleapis.com"
    )
    error_message = "A module-created Redis key must materialize the target project's Redis service agent before granting IAM."
  }

  # CKV_GCP_43: every module-created CMEK key rotates within 90 days.
  assert {
    condition     = google_kms_crypto_key.redis[0].rotation_period == "7776000s"
    error_message = "A module-created Memorystore CryptoKey must rotate every 90 days."
  }
}

run "existing_redis_key_creates_no_key_or_iam" {
  command = plan

  variables {
    existing_redis_kms_key_id = "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/redis"
  }

  assert {
    condition     = length(google_kms_key_ring.n8n) == 0
    error_message = "An existing key must not require a module-managed key ring."
  }

  assert {
    condition     = length(google_kms_crypto_key.redis) == 0
    error_message = "An existing key must not be created."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.redis) == 0
    error_message = "An existing key must get no module-managed IAM grant."
  }

  assert {
    condition     = google_redis_instance.n8n[0].customer_managed_key == "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/redis"
    error_message = "The managed instance must use the supplied existing key."
  }
}

run "create_and_existing_redis_key_are_mutually_exclusive" {
  command = plan

  variables {
    create_redis_kms_key      = true
    existing_redis_kms_key_id = "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/redis"
  }

  expect_failures = [var.create_redis_kms_key]
}

run "module_created_redis_key_without_ring_reference_fails" {
  command = plan

  variables {
    create_redis_kms_key = true
    # create_kms_key_ring left false and existing_kms_key_ring_id unset.
  }

  expect_failures = [var.existing_kms_key_ring_id]
}

# ── Opt-in Memorystore RDB persistence (section 18) ───────────────────────────

run "persistence_enabled_wires_rdb_schedule" {
  command = plan

  variables {
    redis_persistence_enabled     = true
    redis_rdb_snapshot_period     = "SIX_HOURS"
    redis_rdb_snapshot_start_time = "2024-01-01T03:00:00Z"
  }

  assert {
    condition     = google_redis_instance.n8n[0].persistence_config[0].persistence_mode == "RDB"
    error_message = "redis_persistence_enabled must set persistence_config.persistence_mode = RDB."
  }

  assert {
    condition     = google_redis_instance.n8n[0].persistence_config[0].rdb_snapshot_period == "SIX_HOURS"
    error_message = "redis_rdb_snapshot_period must set persistence_config.rdb_snapshot_period."
  }

  assert {
    condition     = google_redis_instance.n8n[0].persistence_config[0].rdb_snapshot_start_time == "2024-01-01T03:00:00Z"
    error_message = "redis_rdb_snapshot_start_time must set persistence_config.rdb_snapshot_start_time."
  }
}

run "persistence_enabled_accepts_all_documented_periods" {
  command = plan

  variables {
    redis_persistence_enabled = true
    redis_rdb_snapshot_period = "ONE_HOUR"
  }

  assert {
    condition     = google_redis_instance.n8n[0].persistence_config[0].rdb_snapshot_period == "ONE_HOUR"
    error_message = "ONE_HOUR must be an accepted redis_rdb_snapshot_period value."
  }
}

# Omitting the optional/computed block retains RDB on an existing instance.
# Assert an explicit DISABLED mode, not an empty block. Plan-only mocks cannot
# prove the API transition; verify true -> false -> true on a disposable
# instance using docs/manual-verification-checklist.md, item 11.
run "persistence_disabled_by_default_emits_disabled_mode" {
  command = plan

  assert {
    condition     = google_redis_instance.n8n[0].persistence_config[0].persistence_mode == "DISABLED"
    error_message = "The default must explicitly disable persistence, including on an instance that previously used RDB."
  }
}

run "redis_rdb_snapshot_period_invalid_value_fails" {
  command = plan

  variables {
    redis_rdb_snapshot_period = "TWO_HOURS"
  }

  expect_failures = [var.redis_rdb_snapshot_period]
}

run "redis_rdb_snapshot_start_time_malformed_fails" {
  command = plan

  variables {
    redis_persistence_enabled     = true
    redis_rdb_snapshot_start_time = "not-a-timestamp"
  }

  expect_failures = [var.redis_rdb_snapshot_start_time]
}

run "redis_persistence_ignored_when_external_triggers_warning" {
  command = plan

  variables {
    create_redis_instance     = false
    redis_host                = "10.9.8.8"
    redis_persistence_enabled = true
  }

  expect_failures = [check.redis_tuning_ignored_when_existing]

  assert {
    condition     = length(google_redis_instance.n8n) == 0
    error_message = "External Redis (create_redis_instance = false) must remain untouched by redis_persistence_enabled; no Memorystore instance should be created."
  }
}

run "redis_persistence_schedule_tuning_ignored_when_disabled_triggers_warning" {
  command = plan

  variables {
    redis_persistence_enabled     = false
    redis_rdb_snapshot_period     = "ONE_HOUR"
    redis_rdb_snapshot_start_time = "2024-01-01T03:00:00Z"
  }

  expect_failures = [check.redis_persistence_tuning_ignored_when_disabled]

  assert {
    condition     = google_redis_instance.n8n[0].persistence_config[0].persistence_mode == "DISABLED"
    error_message = "Explicit false must disable persistence even when a previously configured snapshot schedule is left set."
  }
}
