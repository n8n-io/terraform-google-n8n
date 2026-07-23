# ── Memorystore for Redis ─────────────────────────────────────────────────────
# n8n uses Redis as the queue backend distributing executions across workers and
# coordinating multi-main. BASIC tier (no replica), Redis 7.2, transit encryption
# disabled.
#
# auth_enabled defaults to false here; if flipped true, the KEDA worker trigger
# (keda.tf) needs a TriggerAuthentication CRD.

resource "google_redis_instance" "n8n" {
  name           = "${local.name_prefix}-redis"
  project        = var.project_id
  region         = var.gcp_region
  tier           = var.memorystore_tier
  memory_size_gb = var.memorystore_memory_gb
  redis_version  = var.memorystore_redis_version

  authorized_network      = google_compute_network.n8n.id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  auth_enabled            = var.memorystore_auth_enabled
  transit_encryption_mode = "DISABLED"

  labels = local.gcp_labels

  # Depending on the time_sleep (not the connection directly) also delays the
  # peering's destruction until after this instance is gone; see network.tf.
  depends_on = [time_sleep.wait_for_psa_cleanup]
}
