# Plan-time tests for PostgreSQL server-certificate verification
# (db_postgresdb_ssl_reject_unauthorized / db_postgresdb_ssl_ca_secret_ref)
# and Cloud SQL server-side TLS enforcement (postgres_ssl_mode).
#
# db_postgresdb_ssl_reject_unauthorized is validated to only ever be true on
# the external PostgreSQL path (create_postgres_instance = false): the
# module-managed Cloud SQL instance always connects over its private IP,
# whose certificate never names that IP as a Subject Alternative Name, so
# certificate verification would deterministically fail the TLS handshake
# there. See docs/postgresql-tls.md for the full explanation.
#
# helm_release.n8n.values is a JSON-encoded string, unknown at plan time
# under the mock provider (AGENTS.md's known mock-provider limitations), so
# the rendered extraEnv/extraVolumes/extraVolumeMounts shape is asserted
# against local.n8n_postgres_ssl_env/n8n_postgres_ssl_ca_volume/
# n8n_postgres_ssl_ca_mount directly (permitted per AGENTS.md: "A terraform
# test assert condition can reference module local.* values directly").

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

# ── Defaults preserve existing behavior exactly ─────────────────────────────

run "defaults_render_unverified_ssl_disabled_env" {
  command = plan

  assert {
    condition     = length(local.n8n_postgres_ssl_env) == 1
    error_message = "db_postgresdb_ssl_enabled defaults to false and must render exactly one env entry."
  }

  assert {
    condition     = one([for e in local.n8n_postgres_ssl_env : e.value if e.name == "DB_POSTGRESDB_SSL_ENABLED"]) == "false"
    error_message = "DB_POSTGRESDB_SSL_ENABLED must default to \"false\"."
  }

  assert {
    condition     = local.manage_postgres_ssl_ca == false
    error_message = "manage_postgres_ssl_ca must default to false."
  }
}

run "ssl_enabled_without_verification_matches_previous_hardcoded_behavior" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled = true
  }

  assert {
    condition     = length(local.n8n_postgres_ssl_env) == 2
    error_message = "db_postgresdb_ssl_enabled = true must render exactly two env entries when reject_unauthorized stays at its default."
  }

  assert {
    condition     = one([for e in local.n8n_postgres_ssl_env : e.value if e.name == "DB_POSTGRESDB_SSL_ENABLED"]) == "true"
    error_message = "DB_POSTGRESDB_SSL_ENABLED must be \"true\" when db_postgresdb_ssl_enabled = true."
  }

  assert {
    condition     = one([for e in local.n8n_postgres_ssl_env : e.value if e.name == "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED"]) == "false"
    error_message = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED must stay \"false\" (matching the previously hardcoded value) when db_postgresdb_ssl_reject_unauthorized is left at its default, so existing callers see no plan diff."
  }
}

# ── db_postgresdb_ssl_reject_unauthorized is rejected on the managed path ───

run "reject_unauthorized_rejected_on_default_managed_path" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    # create_postgres_instance left at its default (true).
  }

  expect_failures = [var.db_postgresdb_ssl_reject_unauthorized]
}

run "reject_unauthorized_requires_ssl_enabled" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_reject_unauthorized = true
    # db_postgresdb_ssl_enabled left at its default (false).
  }

  expect_failures = [var.db_postgresdb_ssl_reject_unauthorized]
}

# ── db_postgresdb_ssl_reject_unauthorized works on the external path ────────

run "reject_unauthorized_allowed_on_external_path_without_ca" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
  }

  assert {
    condition     = one([for e in local.n8n_postgres_ssl_env : e.value if e.name == "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED"]) == "true"
    error_message = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED must be \"true\" once enabled on the external path."
  }

  assert {
    condition     = local.manage_postgres_ssl_ca == false
    error_message = "manage_postgres_ssl_ca must stay false when no CA secret ref is supplied; verification falls back to the pod image's bundled trust store."
  }

  assert {
    condition     = length([for e in local.n8n_postgres_ssl_env : e if e.name == "DB_POSTGRESDB_SSL_CA_FILE"]) == 0
    error_message = "DB_POSTGRESDB_SSL_CA_FILE must not render when no CA secret ref is supplied."
  }
}

run "reject_unauthorized_with_ca_secret_ref_renders_volume_mount_and_env" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_secret_ref = {
      name = "postgres-server-ca"
    }
  }

  assert {
    condition     = local.manage_postgres_ssl_ca == true
    error_message = "manage_postgres_ssl_ca must be true once both reject_unauthorized and the CA secret ref are set."
  }

  assert {
    condition     = local.n8n_postgres_ssl_ca_volume.secret.secretName == "postgres-server-ca" && local.n8n_postgres_ssl_ca_volume.secret.items[0].key == "ca.crt"
    error_message = "n8n_postgres_ssl_ca_volume must reference the caller's Secret name, defaulting key to \"ca.crt\"."
  }

  assert {
    condition     = local.n8n_postgres_ssl_ca_mount.mountPath == "/etc/n8n-certs/postgres-ssl-ca.crt" && local.n8n_postgres_ssl_ca_mount.readOnly == true
    error_message = "n8n_postgres_ssl_ca_mount must mount the CA read-only at the documented path."
  }

  assert {
    condition     = one([for e in local.n8n_postgres_ssl_env : e.value if e.name == "DB_POSTGRESDB_SSL_CA_FILE"]) == "/etc/n8n-certs/postgres-ssl-ca.crt"
    error_message = "DB_POSTGRESDB_SSL_CA_FILE must point at the mounted CA file path."
  }
}

run "ca_secret_ref_accepts_custom_key" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_secret_ref = {
      name = "postgres-server-ca"
      key  = "tls.crt"
    }
  }

  assert {
    condition     = local.n8n_postgres_ssl_ca_volume.secret.items[0].key == "tls.crt"
    error_message = "A custom key on db_postgresdb_ssl_ca_secret_ref must override the \"ca.crt\" default."
  }
}

run "ca_secret_ref_rejects_blank_name" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_secret_ref = {
      name = "   "
    }
  }

  expect_failures = [var.db_postgresdb_ssl_ca_secret_ref]
}

run "ca_secret_ref_rejects_blank_key" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_secret_ref = {
      name = "postgres-server-ca"
      key  = ""
    }
  }

  expect_failures = [var.db_postgresdb_ssl_ca_secret_ref]
}

# ── Cloud SQL server-side ssl_mode (postgres_ssl_mode) ──────────────────────

run "postgres_ssl_mode_defaults_to_allow_unencrypted_and_encrypted" {
  command = plan

  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].ip_configuration[0].ssl_mode == "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    error_message = "postgres_ssl_mode must default to ALLOW_UNENCRYPTED_AND_ENCRYPTED, preserving existing behavior."
  }
}

run "postgres_ssl_mode_encrypted_only_renders_on_instance" {
  command = plan

  variables {
    db_postgresdb_ssl_enabled = true
    postgres_ssl_mode         = "ENCRYPTED_ONLY"
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].ip_configuration[0].ssl_mode == "ENCRYPTED_ONLY"
    error_message = "postgres_ssl_mode = ENCRYPTED_ONLY must reach the Cloud SQL instance's ip_configuration.ssl_mode."
  }
}

run "postgres_ssl_mode_rejects_malformed_value" {
  command = plan

  variables {
    postgres_ssl_mode = "REQUIRE"
  }

  expect_failures = [var.postgres_ssl_mode]
}

run "postgres_ssl_mode_encrypted_only_requires_client_ssl_enabled" {
  command = plan

  variables {
    postgres_ssl_mode = "ENCRYPTED_ONLY"
    # db_postgresdb_ssl_enabled left at its default (false).
  }

  expect_failures = [var.postgres_ssl_mode]
}

# ── Opposite-path diagnostics ────────────────────────────────────────────────

run "postgres_ssl_mode_ignored_when_external_triggers_warning" {
  command = plan

  variables {
    create_postgres_instance  = false
    n8n_database_host         = "pg.external.example.com"
    n8n_database_password     = "external-db-password"
    postgres_ssl_mode         = "ENCRYPTED_ONLY"
    db_postgresdb_ssl_enabled = true
  }

  expect_failures = [check.postgres_tuning_ignored_when_external]
}

run "ca_secret_ref_ignored_when_managed_triggers_warning" {
  command = plan

  variables {
    db_postgresdb_ssl_ca_secret_ref = {
      name = "should-be-ignored"
    }
  }

  expect_failures = [check.postgres_host_and_password_ignored_when_managed]
}

run "postgres_ssl_mode_encrypted_only_not_rejected_on_external_path" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "pg.external.example.com"
    n8n_database_password    = "external-db-password"
    postgres_ssl_mode        = "ENCRYPTED_ONLY"
    # db_postgresdb_ssl_enabled left at its default (false): postgres_ssl_mode
    # is documented as "Ignored when create_postgres_instance = false", so this
    # combination must not trip the ENCRYPTED_ONLY validation on the external
    # path, only the soft postgres_tuning_ignored_when_external warning.
  }

  expect_failures = [check.postgres_tuning_ignored_when_external]
}

run "ssl_enabled_null_falls_back_to_default_not_a_null_condition_crash" {
  command = plan

  variables {
    postgres_ssl_mode         = "ENCRYPTED_ONLY"
    db_postgresdb_ssl_enabled = null
    # db_postgresdb_ssl_enabled is nullable = false with a default: Terraform
    # substitutes the default (false) for an explicit null rather than
    # propagating it, so the ENCRYPTED_ONLY validation below sees a real
    # boolean and fires its own clear error_message instead of a generic
    # null-condition type error.
  }

  expect_failures = [var.postgres_ssl_mode]
}
