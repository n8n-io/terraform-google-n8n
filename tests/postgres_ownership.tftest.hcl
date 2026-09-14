# Plan-time tests for the section 5 PostgreSQL ownership: count-gating the
# Cloud SQL instance, generated password, database, user, and Cloud-SQL-only
# IAM (create_postgres_instance), the direct-password and existing-Secret
# password sources for external PostgreSQL, restore/clone source validation,
# and the module-created/existing Cloud KMS key contract.

mock_provider "google" {
  mock_data "google_sql_database_instance" {
    defaults = {
      database_version = "POSTGRES_16"
    }
  }
}
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

# ── Defaults create every managed Cloud SQL resource ──────────────────────────

run "defaults_create_managed_postgres_resources" {
  command = plan

  assert {
    condition     = length(google_sql_database_instance.n8n) == 1
    error_message = "create_postgres_instance defaults to true and must create the Cloud SQL instance."
  }

  assert {
    condition     = length(random_password.db_password) == 1
    error_message = "create_postgres_instance defaults to true and must generate a database password."
  }

  assert {
    condition     = length(google_sql_database.n8n) == 1
    error_message = "create_postgres_instance defaults to true and must create the database."
  }

  assert {
    condition     = length(google_sql_user.n8n) == 1
    error_message = "create_postgres_instance defaults to true and must create the database user."
  }

  assert {
    condition     = length(google_project_iam_member.n8n_cloudsql_client) == 1
    error_message = "create_postgres_instance defaults to true and must create the Cloud SQL client IAM binding."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_db) == 1
    error_message = "The managed path must create the generated-password Secret."
  }
}

# ── External PostgreSQL with a direct password creates no Cloud SQL resources ─

run "external_postgres_direct_password_creates_no_cloudsql_resources" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    n8n_database_password    = "external-db-password"
  }

  assert {
    condition     = length(google_sql_database_instance.n8n) == 0
    error_message = "create_postgres_instance = false must not create a Cloud SQL instance."
  }

  assert {
    condition     = length(random_password.db_password) == 0
    error_message = "create_postgres_instance = false must not generate a database password."
  }

  assert {
    condition     = length(google_sql_database.n8n) == 0
    error_message = "create_postgres_instance = false must not create a database."
  }

  assert {
    condition     = length(google_sql_user.n8n) == 0
    error_message = "create_postgres_instance = false must not create a database user."
  }

  assert {
    condition     = length(google_project_iam_member.n8n_cloudsql_client) == 0
    error_message = "create_postgres_instance = false must not create the Cloud SQL client IAM binding."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_db) == 1
    error_message = "A direct external password must still be wrapped in the module-managed Secret."
  }

  assert {
    condition     = output.postgres_host == "10.9.8.7"
    error_message = "postgres_host must resolve to the supplied n8n_database_host."
  }

  assert {
    condition     = output.postgres_private_ip == null
    error_message = "postgres_private_ip must be null for external PostgreSQL."
  }

  assert {
    condition     = output.postgres_connection_name == null
    error_message = "postgres_connection_name must be null for external PostgreSQL."
  }

  assert {
    condition     = output.postgres_kms_key_id == null
    error_message = "postgres_kms_key_id must be null for external PostgreSQL."
  }
}

# ── External PostgreSQL with an existing Secret reference creates no Secret ──

run "external_postgres_secret_reference_creates_no_managed_secret" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    n8n_database_password_secret_ref = {
      name = "external-db-credentials"
      key  = "db-password"
    }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_db) == 0
    error_message = "An existing Secret reference must not create the module-managed db Secret."
  }
}

# ── Password source completeness/mutual exclusivity ───────────────────────────

run "external_postgres_missing_password_source_fails_validation" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    # Neither n8n_database_password nor n8n_database_password_secret_ref set.
  }

  expect_failures = [var.n8n_database_password_secret_ref]
}

run "external_postgres_both_password_sources_fails_validation" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    n8n_database_password    = "external-db-password"
    n8n_database_password_secret_ref = {
      name = "external-db-credentials"
    }
  }

  expect_failures = [var.n8n_database_password_secret_ref]
}

# ── Opposite-path diagnostics ─────────────────────────────────────────────────

run "postgres_tuning_ignored_when_external_triggers_warning" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    n8n_database_password    = "external-db-password"
    postgres_machine_type    = "db-custom-4-15360"
  }

  expect_failures = [check.postgres_tuning_ignored_when_external]
}

run "postgres_host_and_password_ignored_when_managed_triggers_warning" {
  command = plan

  variables {
    n8n_database_password = "should-be-ignored"
  }

  expect_failures = [check.postgres_host_and_password_ignored_when_managed]
}

# ── Restore / clone source ────────────────────────────────────────────────────

run "clone_and_restore_are_mutually_exclusive" {
  command = plan

  variables {
    postgres_clone_source_instance_name   = "source-instance"
    postgres_restore_backup_run_id        = 123
    postgres_restore_source_instance_name = "source-instance"
  }

  expect_failures = [var.postgres_clone_source_instance_name]
}

run "restore_backup_run_id_requires_source_instance_name" {
  command = plan

  variables {
    postgres_restore_backup_run_id = 123
    # postgres_restore_source_instance_name intentionally unset
  }

  expect_failures = [var.postgres_restore_source_instance_name, check.postgres_restore_without_encryption_key_continuity]
}

run "restore_source_instance_name_requires_backup_run_id" {
  command = plan

  variables {
    postgres_restore_source_instance_name = "source-instance"
  }

  expect_failures = [var.postgres_restore_source_instance_name]
}

run "clone_point_in_time_requires_source_instance_name" {
  command = plan

  variables {
    postgres_clone_point_in_time = "2026-08-14T12:00:00Z"
  }

  expect_failures = [var.postgres_clone_point_in_time]
}

run "clone_source_requires_managed_instance" {
  command = plan

  variables {
    create_postgres_instance            = false
    n8n_database_host                   = "10.9.8.7"
    n8n_database_password               = "external-db-password"
    postgres_clone_source_instance_name = "source-instance"
  }

  expect_failures = [var.postgres_clone_source_instance_name]
}

run "clone_source_wires_into_managed_instance" {
  command = plan

  variables {
    postgres_clone_source_instance_name = "source-instance"
  }

  expect_failures = [check.postgres_restore_without_encryption_key_continuity]

  assert {
    condition     = google_sql_database_instance.n8n[0].clone[0].source_instance_name == "source-instance"
    error_message = "postgres_clone_source_instance_name must populate the instance's clone block."
  }

  assert {
    condition     = length(data.google_sql_database_instance.restore_source) == 1
    error_message = "A clone source must be read for the observable version-compatibility check."
  }
}

run "clone_source_version_mismatch_fails" {
  command = plan

  variables {
    postgres_clone_source_instance_name = "source-instance"
  }

  override_data {
    target = data.google_sql_database_instance.restore_source
    values = {
      database_version = "POSTGRES_15"
    }
  }

  expect_failures = [data.google_sql_database_instance.restore_source, check.postgres_restore_without_encryption_key_continuity]
}

run "restore_or_clone_source_warns_about_encryption_key_continuity" {
  command = plan

  variables {
    postgres_clone_source_instance_name = "source-instance"
  }

  expect_failures = [check.postgres_restore_without_encryption_key_continuity]
}

run "existing_core_secret_preserves_restore_encryption_key_continuity" {
  command = plan

  variables {
    postgres_clone_source_instance_name = "source-instance"
    existing_n8n_core_secret_name       = "restored-core-secret"
    n8n_license_key                     = null
    n8n_license_key_secret_ref = {
      name = "n8n-license"
    }
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "A restored deployment using an existing core Secret must not generate a replacement encryption key."
  }
}

run "direct_encryption_key_preserves_restore_continuity" {
  command = plan

  variables {
    postgres_clone_source_instance_name = "source-instance"
    n8n_encryption_key                  = "620f6e8fefc19a18f8c87ee7766d7d448f8fbc1648a740ac6192d1c5dc475a04"
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "A restore/clone with a caller-supplied direct n8n_encryption_key must not generate a replacement encryption key."
  }
}

run "direct_encryption_key_does_not_bypass_restore_source_validation" {
  command = plan

  variables {
    postgres_clone_source_instance_name   = "source-instance"
    postgres_restore_source_instance_name = "other-source-instance"
    postgres_restore_backup_run_id        = 12345
    n8n_encryption_key                    = "620f6e8fefc19a18f8c87ee7766d7d448f8fbc1648a740ac6192d1c5dc475a04"
  }

  expect_failures = [var.postgres_clone_source_instance_name]
}

# ── Cloud KMS create-or-reference ─────────────────────────────────────────────

run "module_created_postgres_key_wires_key_ring_and_iam" {
  command = plan

  variables {
    create_kms_key_ring     = true
    create_postgres_kms_key = true
  }

  assert {
    condition     = length(google_kms_key_ring.n8n) == 1
    error_message = "create_kms_key_ring = true must create the shared key ring."
  }

  assert {
    condition     = length(google_kms_crypto_key.postgres) == 1
    error_message = "create_postgres_kms_key = true must create the Cloud SQL CryptoKey."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.postgres) == 1
    error_message = "A module-created key must grant the Cloud SQL service agent IAM."
  }

  assert {
    condition = (
      length(google_project_service_identity.postgres) == 1 &&
      google_project_service_identity.postgres[0].project == "test-project" &&
      google_project_service_identity.postgres[0].service == "sqladmin.googleapis.com"
    )
    error_message = "A module-created Cloud SQL key must materialize the target project's Cloud SQL service agent before granting IAM."
  }
}

run "existing_postgres_key_creates_no_key_or_iam" {
  command = plan

  variables {
    existing_postgres_kms_key_id = "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/pg"
  }

  assert {
    condition     = length(google_kms_key_ring.n8n) == 0
    error_message = "An existing key must not require a module-managed key ring."
  }

  assert {
    condition     = length(google_kms_crypto_key.postgres) == 0
    error_message = "An existing key must not be created."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.postgres) == 0
    error_message = "An existing key must get no module-managed IAM grant."
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].encryption_key_name == "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/pg"
    error_message = "The managed instance must use the supplied existing key."
  }
}

run "create_and_existing_postgres_key_are_mutually_exclusive" {
  command = plan

  variables {
    create_postgres_kms_key      = true
    existing_postgres_kms_key_id = "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/pg"
  }

  expect_failures = [var.create_postgres_kms_key]
}

run "module_created_key_without_ring_reference_fails" {
  command = plan

  variables {
    create_postgres_kms_key = true
    # create_kms_key_ring left false and existing_kms_key_ring_id unset.
  }

  expect_failures = [var.existing_kms_key_ring_id]
}

run "postgres_kms_ignored_when_external_triggers_warning" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    n8n_database_password    = "external-db-password"
    create_postgres_kms_key  = true
    create_kms_key_ring      = true
  }

  expect_failures = [check.postgres_kms_ignored_when_external]

  assert {
    condition = (
      length(google_kms_key_ring.n8n) == 0 &&
      length(google_kms_crypto_key.postgres) == 0 &&
      length(google_kms_crypto_key_iam_member.postgres) == 0
    )
    error_message = "Ignored PostgreSQL CMEK inputs must not create a key ring, key, or IAM binding for an external database."
  }
}
