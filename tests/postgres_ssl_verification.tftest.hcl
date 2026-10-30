# Plan-time tests for PostgreSQL server-certificate verification
# (db_postgresdb_ssl_reject_unauthorized / db_postgresdb_ssl_ca_pem)
# and Cloud SQL server-side TLS enforcement (postgres_ssl_mode).
#
# db_postgresdb_ssl_reject_unauthorized is validated to only ever be true on
# the external PostgreSQL path (create_postgres_instance = false): the
# module-managed Cloud SQL instance always connects over its private IP,
# and Google documents Cloud SQL hostname verification only by DNS name, so
# n8n's hostname check is expected to fail the TLS handshake there.
# See docs/postgresql-tls.md for the full explanation.
#
# How the pinned chart renders database.ssl (DB_POSTGRESDB_SSL_CA in its
# ConfigMap, consumed by every role, with a checksum/config annotation that
# changes with the CA) is covered by tests/scripts/check-n8n-chart.sh, not
# here.
#
# helm_release.n8n.values is unknown at plan time under the mock provider
# (AGENTS.md's known mock-provider limitations), so the database.ssl and
# extraEnv fragments are asserted against local.n8n_database_ssl_values and
# local.n8n_postgres_ssl_env directly (permitted per AGENTS.md: "A terraform
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
    condition     = local.postgres_ssl_ca_active == false && length(keys(local.n8n_database_ssl_values)) == 0
    error_message = "No database.ssl chart value may render by default, so existing callers see no Helm values diff."
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
    condition     = local.postgres_ssl_ca_active == false && length(keys(local.n8n_database_ssl_values)) == 0
    error_message = "No database.ssl chart value may render when no CA is supplied; verification falls back to the pod image's bundled trust store."
  }

  assert {
    condition     = length(local.n8n_postgres_ssl_env) == 2
    error_message = "Verification without a CA must render only DB_POSTGRESDB_SSL_ENABLED and DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED."
  }
}

run "reject_unauthorized_with_ca_pem_renders_chart_database_ssl" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = local.postgres_ssl_ca_active == true
    error_message = "postgres_ssl_ca_active must be true once both reject_unauthorized and the CA are set."
  }

  assert {
    condition     = local.n8n_database_ssl_values.ssl.ca == "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
    error_message = "database.ssl.ca must carry the caller's PEM bundle."
  }

  # The chart renders DB_POSTGRESDB_SSL_CA only when database.ssl.enabled is
  # true, and renders its own DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED only when
  # database.ssl.rejectUnauthorized is false.
  assert {
    condition     = local.n8n_database_ssl_values.ssl.enabled == true && local.n8n_database_ssl_values.ssl.rejectUnauthorized == true
    error_message = "database.ssl must set enabled = true and rejectUnauthorized = true so the chart renders the CA and no duplicate DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED."
  }

  # Chart >= 1.15.0 renders DB_POSTGRESDB_SSL_ENABLED itself (n8n-hosting#175)
  # once database.ssl.enabled is true, so the module must not add a second
  # entry for the same name.
  assert {
    condition     = local.n8n_chart_renders_postgres_ssl_enabled == true && length(local.n8n_postgres_ssl_env) == 1 && one([for e in local.n8n_postgres_ssl_env : e.value if e.name == "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED"]) == "true"
    error_message = "On chart 1.15.0 with a CA the module's extraEnv must keep only DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED; the chart owns DB_POSTGRESDB_SSL_ENABLED and the CA."
  }
}

run "ca_pem_on_chart_before_1_15_keeps_module_ssl_enabled_entry" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
    n8n_chart_version                     = "1.14.0"
  }

  # Charts before 1.15.0 render DB_POSTGRESDB_SSL (which n8n does not read), not
  # DB_POSTGRESDB_SSL_ENABLED, so the module keeps its own entry rather than
  # rely on n8n deriving TLS from the CA alone.
  assert {
    condition     = local.n8n_chart_renders_postgres_ssl_enabled == false && length(local.n8n_postgres_ssl_env) == 2 && one([for e in local.n8n_postgres_ssl_env : e.value if e.name == "DB_POSTGRESDB_SSL_ENABLED"]) == "true"
    error_message = "On chart 1.14.0 the module must keep emitting DB_POSTGRESDB_SSL_ENABLED=true next to DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED."
  }
}

run "ca_pem_on_unverifiable_chart_repository_keeps_module_ssl_enabled_entry" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
    n8n_chart_repository                  = "oci://registry.example.com/mirror/n8n-helm-chart"
  }

  # A mirror's chart contents cannot be verified, so the module keeps its own
  # entry: a duplicate with the same value does not change n8n's effective
  # TLS configuration.
  assert {
    condition     = local.n8n_chart_renders_postgres_ssl_enabled == false && length(local.n8n_postgres_ssl_env) == 2
    error_message = "On a custom chart repository the module must keep emitting DB_POSTGRESDB_SSL_ENABLED=true."
  }
}

run "ca_pem_on_prerelease_chart_keeps_module_ssl_enabled_entry" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
    n8n_chart_version                     = "1.15.0-rc.1"
  }

  # A prerelease tag may predate the ConfigMap key the chart needs to render
  # DB_POSTGRESDB_SSL_ENABLED itself (n8n-hosting#175), so the module keeps
  # its own entry rather than rely on unverified chart behavior.
  assert {
    condition     = local.n8n_chart_renders_postgres_ssl_enabled == false && length(local.n8n_postgres_ssl_env) == 2 && one([for e in local.n8n_postgres_ssl_env : e.value if e.name == "DB_POSTGRESDB_SSL_ENABLED"]) == "true"
    error_message = "On a prerelease chart version the module must keep emitting DB_POSTGRESDB_SSL_ENABLED=true next to DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED."
  }
}

run "ca_pem_on_release_with_build_metadata_treats_it_as_the_release" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
    n8n_chart_version                     = "1.15.0+build.5"
  }

  # Build metadata after "+" is not a prerelease, so it must still count as
  # the release and the module must not duplicate DB_POSTGRESDB_SSL_ENABLED.
  assert {
    condition     = local.n8n_chart_renders_postgres_ssl_enabled == true && length(local.n8n_postgres_ssl_env) == 1
    error_message = "On chart 1.15.0+build.5 the module must defer DB_POSTGRESDB_SSL_ENABLED to the chart, same as a plain 1.15.0 release."
  }
}

run "ca_pem_on_newer_minor_release_defers_to_chart" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
    n8n_chart_version                     = "1.16.0"
  }

  assert {
    condition     = local.n8n_chart_renders_postgres_ssl_enabled == true && length(local.n8n_postgres_ssl_env) == 1
    error_message = "On chart 1.16.0 the module must defer DB_POSTGRESDB_SSL_ENABLED to the chart."
  }
}

run "ca_pem_is_whitespace_trimmed" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "\n  -----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----\n\n"
  }

  assert {
    condition     = local.n8n_database_ssl_values.ssl.ca == "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
    error_message = "database.ssl.ca must be whitespace-trimmed, so a trailing newline in the caller's file does not roll the pods."
  }
}

run "ca_pem_accepts_multi_certificate_bundle" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nQQ==\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nQg==\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition     = local.postgres_ssl_ca_active == true
    error_message = "A bundle with more than one certificate must pass validation."
  }
}

run "ca_pem_rejects_non_pem_value" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "not a certificate"
  }

  expect_failures = [var.db_postgresdb_ssl_ca_pem]
}

run "ca_pem_rejects_blank_value" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "   "
  }

  expect_failures = [var.db_postgresdb_ssl_ca_pem]
}

# The size limit is 131050 bytes in UTF-8 after trimming (see the validation
# comment in variables.tf). PEM framing is 54 bytes: 27 + 25 + two line breaks.
# length() counts grapheme clusters, so "ő" (two bytes) and CRLF (two bytes)
# each count once there; the runs below sit on each side of the byte limit.

# 54 + 130996 ASCII body = 131050 bytes, with surrounding whitespace trimmed.
run "ca_pem_accepts_exactly_131050_bytes_after_trimming" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "\n-----BEGIN CERTIFICATE-----\n${format("%0130996d", 0)}\n-----END CERTIFICATE-----\n\n"
  }

  assert {
    condition     = length(local.n8n_database_ssl_values.ssl.ca) == 131050
    error_message = "An ASCII bundle of exactly 131050 bytes after trimming must pass validation and reach database.ssl.ca whole."
  }
}

run "ca_pem_rejects_131051_bytes_after_trimming" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\n${format("%0130997d", 0)}\n-----END CERTIFICATE-----"
  }

  expect_failures = [var.db_postgresdb_ssl_ca_pem]
}

# 54 + "ő" (2 bytes) + 130994 = 131050 bytes, 131049 characters.
run "ca_pem_accepts_non_ascii_bundle_at_byte_limit" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nő${format("%0130994d", 0)}\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = length(local.n8n_database_ssl_values.ssl.ca) == 131049
    error_message = "A non-ASCII bundle of exactly 131050 bytes must pass validation and reach database.ssl.ca unchanged."
  }
}

# 54 + "ő" (2 bytes) + 130995 = 131051 bytes, but only 131050 characters.
run "ca_pem_rejects_multibyte_bundle_over_byte_limit" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nő${format("%0130995d", 0)}\n-----END CERTIFICATE-----"
  }

  expect_failures = [var.db_postgresdb_ssl_ca_pem]
}

# RFC 7468 section 5.2 allows explanatory text outside the BEGIN/END lines,
# and Node's tls.connect({ ca }) ignores it, so a non-ASCII label between two
# certificates (as in Mozilla's CA list) must be accepted and delivered as-is.
run "ca_pem_accepts_non_ascii_label_between_certificates" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----\nNetLock Arany (Class Gold) Főtanúsítvány\n-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUI=\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition     = local.n8n_database_ssl_values.ssl.ca == "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----\nNetLock Arany (Class Gold) Főtanúsítvány\n-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUI=\n-----END CERTIFICATE-----"
    error_message = "A bundle with a non-ASCII label between certificates must pass validation and reach database.ssl.ca unchanged (trimmed)."
  }
}

# A realistic Windows-saved bundle: 2015 lines of 64 characters, each ending in
# CRLF, inside the framing. 131028 characters after trimming, which a
# length()-based rule would accept, but 133044 bytes. range() caps at 1024
# values, so the body is built with replace() over a zero-padded string.
run "ca_pem_rejects_windows_line_ending_bundle_over_byte_limit" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\r\n${replace(format("%02015d", 0), "0", "${format("%064d", 1)}\r\n")}-----END CERTIFICATE-----"
  }

  expect_failures = [var.db_postgresdb_ssl_ca_pem]
}

# One CRLF and one LF line break: 131051 bytes, but only 131050 characters,
# because length() counts CRLF as a single grapheme cluster.
run "ca_pem_rejects_crlf_bundle_over_byte_limit" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\r\n${format("%0130996d", 0)}\n-----END CERTIFICATE-----"
  }

  expect_failures = [var.db_postgresdb_ssl_ca_pem]
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

run "ca_pem_ignored_when_managed_triggers_warning" {
  command = plan

  variables {
    db_postgresdb_ssl_ca_pem = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
  }

  assert {
    condition     = local.postgres_ssl_ca_active == false && length(keys(local.n8n_database_ssl_values)) == 0
    error_message = "The CA must not reach the chart on the managed path."
  }

  expect_failures = [check.postgres_host_and_password_ignored_when_managed]
}

run "ca_pem_ignored_without_verification_triggers_warning" {
  command = plan

  variables {
    create_postgres_instance  = false
    n8n_database_host         = "pg.external.example.com"
    n8n_database_password     = "external-db-password"
    db_postgresdb_ssl_enabled = true
    db_postgresdb_ssl_ca_pem  = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
    # db_postgresdb_ssl_reject_unauthorized left at its default (false).
  }

  # Nothing verifies the certificate against the CA in this case, so passing
  # it to the chart would only add a Helm values diff and a pod rollout.
  assert {
    condition     = local.postgres_ssl_ca_active == false && length(keys(local.n8n_database_ssl_values)) == 0
    error_message = "The CA must not reach the chart while db_postgresdb_ssl_reject_unauthorized = false."
  }

  expect_failures = [check.postgres_ssl_ca_ignored_without_verification]
}

# ── NODE_TLS_REJECT_UNAUTHORIZED=0 with no CA bundle ────────────────────────

run "node_tls_env_without_ca_triggers_warning" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    n8n_extra_env = [
      { name = "NODE_TLS_REJECT_UNAUTHORIZED", value = "0" },
    ]
  }

  expect_failures = [check.postgres_ssl_verification_disabled_by_node_tls_env]
}

run "node_tls_env_in_worker_extra_env_without_ca_triggers_warning" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    n8n_worker_extra_env = [
      { name = "NODE_TLS_REJECT_UNAUTHORIZED", value = "0" },
    ]
  }

  expect_failures = [check.postgres_ssl_verification_disabled_by_node_tls_env]
}

run "node_tls_env_in_worker_pool_extra_env_without_ca_triggers_warning" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    # A worker-pools preview build passes helm_release.n8n's pool precondition
    # (see worker-pools.tf, local.n8n_chart_renders_worker_pools).
    n8n_chart_version = "1.11.0-preview.workerpools.1"
    n8n_worker_pools = [{
      name      = "heavy"
      extra_env = [{ name = "NODE_TLS_REJECT_UNAUTHORIZED", value = "0" }]
    }]
  }

  expect_failures = [check.postgres_ssl_verification_disabled_by_node_tls_env]
}

# With a CA bundle, n8n passes an explicit rejectUnauthorized, so the same
# env entry does not affect the database connection and no warning fires.
run "node_tls_env_with_ca_does_not_warn" {
  command = plan

  variables {
    create_postgres_instance              = false
    n8n_database_host                     = "pg.external.example.com"
    n8n_database_password                 = "external-db-password"
    db_postgresdb_ssl_enabled             = true
    db_postgresdb_ssl_reject_unauthorized = true
    db_postgresdb_ssl_ca_pem              = "-----BEGIN CERTIFICATE-----\nU1lOVEhFVElDLUNBLUE=\n-----END CERTIFICATE-----"
    n8n_extra_env = [
      { name = "NODE_TLS_REJECT_UNAUTHORIZED", value = "0" },
    ]
  }

  assert {
    condition     = local.postgres_ssl_ca_active == true
    error_message = "The CA must reach the chart when verification is on and a CA is supplied."
  }
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
