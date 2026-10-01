# ── Cloud SQL for PostgreSQL ──────────────────────────────────────────────────
# Private IP over Private Services Access; SSL is not required on the connection
# (ssl_mode ALLOW_UNENCRYPTED_AND_ENCRYPTED), matching the n8n
# DB_POSTGRESDB_SSL_ENABLED=false path. Regional HA by default.
#
# create_postgres_instance gates the instance, generated password, database,
# user, and Cloud SQL-only IAM bindings (workload_identity.tf's
# n8n_cloudsql_client) as a single unit (D4): with create_postgres_instance =
# false the caller supplies an external host and exactly one password source
# instead (n8n_database_password or n8n_database_password_secret_ref; see
# locals.tf's effective_postgres_* / effective_db_password_secret_* locals and
# n8n.tf's kubernetes_secret.n8n_db).
#
# Generated DB password.
resource "random_password" "db_password" {
  count = var.create_postgres_instance ? 1 : 0

  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# ── Restore/clone source compatibility (managed instance only) ───────────────
# Observable-fact check for D4's "Managed PostgreSQL restore source"
# requirement: the source instance's database_version must match
# postgres_version, since restoring or cloning across engine versions is not
# supported by this module. Prerequisites this cannot observe (e.g. IAM
# permission to read the source) surface as a plan-time data-source error.
data "google_sql_database_instance" "restore_source" {
  count = (var.postgres_clone_source_instance_name != null || var.postgres_restore_source_instance_name != null) ? 1 : 0

  name    = coalesce(var.postgres_clone_source_instance_name, var.postgres_restore_source_instance_name)
  project = var.project_id

  lifecycle {
    postcondition {
      condition     = self.database_version == var.postgres_version
      error_message = "Restore/clone source instance '${self.name}' runs ${self.database_version}, which does not match postgres_version (${var.postgres_version}). Restoring or cloning across engine versions is not supported by this module; set postgres_version to match the source instance."
    }
  }
}

# ── Curated Checkov exceptions for this instance (full rationale; the actual
# checkov:skip directives, which must live inside the resource body to take
# effect, are compact one-liners near the top of the resource below) ─────────
#
# CKV_GCP_51/52/53/54/108/109 and CKV2_GCP_13 (PostgreSQL logging flags):
# log_checkpoints/log_connections/log_disconnections/log_lock_waits/
# log_hostname/log_min_error_statement/log_duration are all set to "on" (or
# "error") below via a dynamic "database_flags" block. Checkov's static
# database_flags checks only recognize literal (non-dynamic) database_flags
# blocks -- reproduced against a minimal two-flag fixture during this
# change's security review, where the identical flags/values passed as
# literal blocks and failed as a dynamic block. Verified instead by
# tests/postgres_ownership.tftest.hcl's always-on-flags assertions.
#
# CKV_GCP_79 (latest major version): postgres_version defaults to
# POSTGRES_16, a fully supported (non-deprecated, extended support through
# 2032) major version; this check hardcodes a single literal "latest"
# version per engine (currently POSTGRES_18 only) that goes stale on every
# new Cloud SQL major release. postgres_version remains caller-configurable
# to any supported version, including the current literal this check
# expects.
#
# CKV_GCP_6 (require SSL): ssl_mode (postgres_ssl_mode) defaults to
# ALLOW_UNENCRYPTED_AND_ENCRYPTED (not ENCRYPTED_ONLY), matching n8n's own
# default DB_POSTGRESDB_SSL_ENABLED=false client behavior over a private VPC
# connection (Private Services Access, never a public IP); see the file-level
# comment and db_postgresdb_ssl_enabled in variables.tf, which lets an
# operator require SSL on the n8n client side without breaking connectivity
# for those who leave it at the documented default. postgres_ssl_mode
# (variables_gcp.tf) opts the instance itself into ENCRYPTED_ONLY for
# server-side enforcement; Checkov only scans the static default below, so
# the skip stays regardless of the variable's actual value.
#
# CKV_GCP_110 (pgAudit): a heavier, opt-in audit-logging feature beyond this
# change's opt-in DDL/slow-query logging (postgres_query_logging_enabled);
# enabling it unconditionally was not requested and is not implied by AWS
# parity. Operators needing pgAudit can add `cloudsql.enable_pgaudit = on` via
# the same for_each map this resource already builds its database_flags from.
#
# CKV_GCP_111 (log every statement): log_statement=all/mod/ddl for every
# instance would override the opt-in postgres_query_logging_enabled
# contract's own documented scope (log_statement=ddl only, and only when
# explicitly enabled) with an always-on, potentially PII-carrying statement
# log; see that variable's description and the design's stated non-goal of
# an AWS-force_ssl-style always-on logging default.
resource "google_sql_database_instance" "n8n" {
  count = var.create_postgres_instance ? 1 : 0

  # checkov:skip=CKV_GCP_51: dynamic-block scanner limitation, see file comment above.
  # checkov:skip=CKV_GCP_52: dynamic-block scanner limitation, see file comment above.
  # checkov:skip=CKV_GCP_53: dynamic-block scanner limitation, see file comment above.
  # checkov:skip=CKV_GCP_54: dynamic-block scanner limitation, see file comment above.
  # checkov:skip=CKV_GCP_108: dynamic-block scanner limitation, see file comment above.
  # checkov:skip=CKV_GCP_109: dynamic-block scanner limitation, see file comment above.
  # checkov:skip=CKV2_GCP_13: dynamic-block scanner limitation, see file comment above.
  # checkov:skip=CKV_GCP_79: intentional, hardcoded-literal scanner limitation, see file comment above.
  # checkov:skip=CKV_GCP_6: intentional design choice, see file comment above.
  # checkov:skip=CKV_GCP_110: intentional, opt-in-scope design choice, see file comment above.
  # checkov:skip=CKV_GCP_111: intentional, opt-in-scope design choice, see file comment above.

  name                = "${local.name_prefix}-pg"
  project             = var.project_id
  region              = var.gcp_region
  database_version    = var.postgres_version
  deletion_protection = var.postgres_deletion_protection
  encryption_key_name = local.effective_postgres_kms_key_id

  # Private IP requires the PSA peering to exist first (network.tf; the
  # connection is abandoned rather than deleted on destroy, so no ordering
  # against its teardown is needed). Also wait for the module-created key's
  # IAM grant (kms.tf) and the observable restore/clone source compatibility
  # check above.
  depends_on = [
    google_service_networking_connection.psa,
    google_kms_crypto_key_iam_member.postgres,
    data.google_sql_database_instance.restore_source,
  ]

  settings {
    edition           = var.postgres_edition
    tier              = var.postgres_machine_type
    availability_type = var.postgres_availability_type
    disk_type         = "PD_SSD"
    disk_size         = var.postgres_disk_size
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = local.effective_network_id
      ssl_mode        = var.postgres_ssl_mode
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
      transaction_log_retention_days = var.postgres_transaction_log_retention_days

      dynamic "backup_retention_settings" {
        for_each = var.postgres_backup_retained_backups != null ? [var.postgres_backup_retained_backups] : []
        content {
          retained_backups = backup_retention_settings.value
          retention_unit   = "COUNT"
        }
      }
    }

    maintenance_window {
      day          = 7
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled = true
    }

    # database_flags combines two groups into a single dynamic block (a
    # static analyzer scanning the raw HCL, not a real plan, does not reliably
    # attribute flags spread across multiple dynamic "database_flags" blocks
    # of the same block type to the same resource):
    #   - Always-on, low-noise audit flags (Checkov CKV_GCP_51/52/53/54/108,
    #     CKV2_GCP_13): connection/disconnection/checkpoint/lock-wait/duration
    #     events and client hostnames, none of which record query text or
    #     parameter values.
    #   - Opt-in DDL/slow-statement logging (postgres_query_logging_enabled),
    #     not AWS's all-statement rds.force_ssl-style logging.
    #     log_min_duration_statement is a duration in milliseconds; logged
    #     statement text may include literal query parameter values (see the
    #     variable's description). Checkov's CKV_GCP_111 (log every statement)
    #     and CKV_GCP_110 (pgAudit) ask for a strictly heavier always-on
    #     posture than this opt-in design intentionally provides; see
    #     parity-matrix.md / the security baseline report for that exception.
    dynamic "database_flags" {
      for_each = merge(
        {
          log_connections         = "on"
          log_disconnections      = "on"
          log_checkpoints         = "on"
          log_lock_waits          = "on"
          log_duration            = "on"
          log_hostname            = "on"
          log_min_error_statement = "error"
        },
        var.postgres_query_logging_enabled ? {
          log_statement              = "ddl"
          log_min_duration_statement = "1000"
        } : {}
      )
      content {
        name  = database_flags.key
        value = database_flags.value
      }
    }

    user_labels = local.gcp_labels
  }

  # Only one of clone/restore_backup_context may be set (enforced by the
  # mutual-exclusivity validation on postgres_clone_source_instance_name); both
  # only take effect the first time the instance is created.
  dynamic "clone" {
    for_each = var.postgres_clone_source_instance_name != null ? [1] : []
    content {
      source_instance_name = var.postgres_clone_source_instance_name
      point_in_time        = var.postgres_clone_point_in_time
    }
  }

  dynamic "restore_backup_context" {
    for_each = var.postgres_restore_backup_run_id != null ? [1] : []
    content {
      backup_run_id = var.postgres_restore_backup_run_id
      instance_id   = var.postgres_restore_source_instance_name
      project       = var.project_id
    }
  }
}

resource "google_sql_database" "n8n" {
  count = var.create_postgres_instance ? 1 : 0

  name     = var.n8n_database_name
  project  = var.project_id
  instance = google_sql_database_instance.n8n[0].name

  # On destroy, drop the instance (which cascades DB + users) rather than issuing
  # an individual DROP DATABASE, that fails while connections exist ("database is
  # being accessed by other users").
  deletion_policy = "ABANDON"
}

resource "google_sql_user" "n8n" {
  count = var.create_postgres_instance ? 1 : 0

  name     = var.n8n_database_user
  project  = var.project_id
  instance = google_sql_database_instance.n8n[0].name
  password = random_password.db_password[0].result

  # ABANDON: don't DROP USER on destroy, it fails because the user owns the n8n
  # schema objects ("role cannot be dropped because some objects depend on it").
  # Deleting the instance removes the user with it.
  deletion_policy = "ABANDON"
}
