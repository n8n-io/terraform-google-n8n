# ── Cloud SQL for PostgreSQL ──────────────────────────────────────────────────
# Private IP over Private Services Access; SSL is not required on the connection
# (ssl_mode ALLOW_UNENCRYPTED_AND_ENCRYPTED), matching the n8n
# DB_POSTGRESDB_SSL_ENABLED=false path. Regional HA by default.
#
# Generated DB password.
resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "google_sql_database_instance" "n8n" {
  name                = "${local.name_prefix}-pg"
  project             = var.project_id
  region              = var.gcp_region
  database_version    = var.postgres_version
  deletion_protection = var.postgres_deletion_protection

  # Private IP requires the PSA peering to exist first. Depending on the
  # time_sleep (not the connection directly) also delays the peering's
  # destruction until after this instance is gone; see network.tf.
  depends_on = [time_sleep.wait_for_psa_cleanup]

  settings {
    edition           = var.postgres_edition
    tier              = var.postgres_machine_type
    availability_type = var.postgres_availability_type
    disk_type         = "PD_SSD"
    disk_size         = var.postgres_disk_size
    disk_autoresize   = true

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.n8n.id
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
}

resource "google_sql_database" "n8n" {
  name     = var.n8n_database_name
  project  = var.project_id
  instance = google_sql_database_instance.n8n.name

  # On destroy, drop the instance (which cascades DB + users) rather than issuing
  # an individual DROP DATABASE, that fails while connections exist ("database is
  # being accessed by other users").
  deletion_policy = "ABANDON"
}

resource "google_sql_user" "n8n" {
  name     = var.n8n_database_user
  project  = var.project_id
  instance = google_sql_database_instance.n8n.name
  password = var.create_postgres_instance ? random_password.db_password.result : var.n8n_database_password

  # ABANDON: don't DROP USER on destroy, it fails because the user owns the n8n
  # schema objects ("role cannot be dropped because some objects depend on it").
  # Deleting the instance removes the user with it.
  deletion_policy = "ABANDON"
}
