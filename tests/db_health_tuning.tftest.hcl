# Plan-time tests for section 4: database health-check ping tuning
# (db_ping_timeout_ms / db_ping_interval_seconds /
# db_ping_max_failures_before_recovery) and the PostgreSQL
# connection-acquisition timeout (db_postgresdb_connection_timeout_ms).
#
# All four settings render through config.extraEnv in helm_release.n8n.values
# (a JSON-encoded string, unknown at plan time under the mock provider - see
# AGENTS.md's known mock-provider limitations), and apply identically for
# managed Cloud SQL and external PostgreSQL since config.extraEnv does not
# distinguish infrastructure ownership. This is asserted at the
# variable-contract layer, mirroring the existing OTEL/log-streaming test
# pattern. To verify the rendered env vars end-to-end on all three n8n roles:
# run `terraform plan` from examples/small/ (managed Cloud SQL) and from an
# external-database configuration with these variables set, and inspect the
# helm_release.n8n plan output directly.

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

# ── Defaults ──────────────────────────────────────────────────────────────────

run "db_health_tuning_defaults_to_null" {
  command = plan

  assert {
    condition = (
      var.db_ping_timeout_ms == null &&
      var.db_ping_interval_seconds == null &&
      var.db_ping_max_failures_before_recovery == null &&
      var.db_postgresdb_connection_timeout_ms == null
    )
    error_message = "All four database health/acquisition tuning variables must default to null so an individual unset value omits its DB_* override and n8n's own default applies."
  }
}

# ── Explicit values propagate on managed Cloud SQL (module default) ─────────

run "db_health_tuning_explicit_values_on_managed_postgres" {
  command = plan

  variables {
    db_ping_timeout_ms                   = 5000
    db_ping_interval_seconds             = 10
    db_ping_max_failures_before_recovery = 3
    db_postgresdb_connection_timeout_ms  = 20000
  }

  assert {
    condition     = var.create_postgres_instance == true
    error_message = "This run exercises the default managed Cloud SQL path."
  }

  assert {
    condition = (
      var.db_ping_timeout_ms == 5000 &&
      var.db_ping_interval_seconds == 10 &&
      var.db_ping_max_failures_before_recovery == 3 &&
      var.db_postgresdb_connection_timeout_ms == 20000
    )
    error_message = "Explicit database health/acquisition tuning values must propagate through the module regardless of PostgreSQL ownership."
  }
}

# ── Explicit values propagate on external PostgreSQL ─────────────────────────

run "db_health_tuning_explicit_values_on_external_postgres" {
  command = plan

  variables {
    create_postgres_instance             = false
    n8n_database_host                    = "external-postgres.example.internal"
    n8n_database_password                = "not-a-real-password"
    db_ping_timeout_ms                   = 5000
    db_ping_interval_seconds             = 10
    db_ping_max_failures_before_recovery = 3
    db_postgresdb_connection_timeout_ms  = 0
  }

  assert {
    condition = (
      var.db_ping_timeout_ms == 5000 &&
      var.db_ping_interval_seconds == 10 &&
      var.db_ping_max_failures_before_recovery == 3 &&
      var.db_postgresdb_connection_timeout_ms == 0
    )
    error_message = "Explicit database health/acquisition tuning values, including a zero acquisition timeout that disables it, must propagate on external PostgreSQL."
  }
}

# ── db_ping_timeout_ms validation ────────────────────────────────────────────

run "db_ping_timeout_ms_rejects_negative" {
  command = plan

  variables {
    db_ping_timeout_ms = -1
  }

  expect_failures = [var.db_ping_timeout_ms]
}

run "db_ping_timeout_ms_rejects_fractional" {
  command = plan

  variables {
    db_ping_timeout_ms = 500.5
  }

  expect_failures = [var.db_ping_timeout_ms]
}

run "db_ping_timeout_ms_rejects_zero" {
  command = plan

  variables {
    db_ping_timeout_ms = 0
  }

  expect_failures = [var.db_ping_timeout_ms]
}

# ── db_ping_interval_seconds validation ──────────────────────────────────────

run "db_ping_interval_seconds_rejects_negative" {
  command = plan

  variables {
    db_ping_interval_seconds = -5
  }

  expect_failures = [var.db_ping_interval_seconds]
}

run "db_ping_interval_seconds_rejects_fractional" {
  command = plan

  variables {
    db_ping_interval_seconds = 2.5
  }

  expect_failures = [var.db_ping_interval_seconds]
}

# ── db_ping_max_failures_before_recovery validation ─────────────────────────

run "db_ping_max_failures_before_recovery_rejects_negative" {
  command = plan

  variables {
    db_ping_max_failures_before_recovery = -2
  }

  expect_failures = [var.db_ping_max_failures_before_recovery]
}

run "db_ping_max_failures_before_recovery_rejects_fractional" {
  command = plan

  variables {
    db_ping_max_failures_before_recovery = 1.5
  }

  expect_failures = [var.db_ping_max_failures_before_recovery]
}

# ── db_postgresdb_connection_timeout_ms validation (0-2147483647) ───────────

run "db_postgresdb_connection_timeout_ms_accepts_zero_to_disable" {
  command = plan

  variables {
    db_postgresdb_connection_timeout_ms = 0
  }

  assert {
    condition     = var.db_postgresdb_connection_timeout_ms == 0
    error_message = "db_postgresdb_connection_timeout_ms must accept zero to disable the acquisition timeout."
  }
}

run "db_postgresdb_connection_timeout_ms_rejects_negative" {
  command = plan

  variables {
    db_postgresdb_connection_timeout_ms = -1
  }

  expect_failures = [var.db_postgresdb_connection_timeout_ms]
}

run "db_postgresdb_connection_timeout_ms_rejects_overflow" {
  command = plan

  variables {
    db_postgresdb_connection_timeout_ms = 2147483648
  }

  expect_failures = [var.db_postgresdb_connection_timeout_ms]
}

run "db_postgresdb_connection_timeout_ms_accepts_upper_bound" {
  command = plan

  variables {
    db_postgresdb_connection_timeout_ms = 2147483647
  }

  assert {
    condition     = var.db_postgresdb_connection_timeout_ms == 2147483647
    error_message = "db_postgresdb_connection_timeout_ms must accept the documented upper bound of 2147483647."
  }
}

run "db_postgresdb_connection_timeout_ms_rejects_fractional" {
  command = plan

  variables {
    db_postgresdb_connection_timeout_ms = 100.5
  }

  expect_failures = [var.db_postgresdb_connection_timeout_ms]
}

# ── n8n_extra_env collision: the existing "DB_" prefix guard already covers
# these four new names (local.n8n_managed_env_prefixes in locals.tf), but the
# regression is asserted explicitly here per task 4.2/4.3's collision
# requirement and to keep this section self-contained if the guard's shape
# ever changes.

run "extra_env_rejects_db_ping_timeout_ms_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_PING_TIMEOUT_MS", value = "1000" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_db_postgresdb_connection_timeout_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "DB_POSTGRESDB_CONNECTION_TIMEOUT", value = "0" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}
