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

resource "google_sql_database_instance" "n8n" {
  count = var.create_postgres_instance ? 1 : 0

  name                = "${local.name_prefix}-pg"
  project             = var.project_id
  region              = var.gcp_region
  database_version    = var.postgres_version
  deletion_protection = var.postgres_deletion_protection
  encryption_key_name = local.effective_postgres_kms_key_id

  # Private IP requires the PSA peering to exist first. Depending on the
  # time_sleep (not the connection directly) also delays the peering's
  # destruction until after this instance is gone; see network.tf. Also wait
  # for the module-created key's IAM grant (kms.tf) and the observable
  # restore/clone source compatibility check above.
  depends_on = [
    time_sleep.wait_for_psa_cleanup,
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
      ssl_mode        = "ALLOW_UNENCRYPTED_AND_ENCRYPTED"
    }

    backup_configuration {
      enabled                        = true
      point_in_time_recovery_enabled = true
      start_time                     = "03:00"
    }

    maintenance_window {
      day          = 7
      hour         = 4
      update_track = "stable"
    }

    insights_config {
      query_insights_enabled = true
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
