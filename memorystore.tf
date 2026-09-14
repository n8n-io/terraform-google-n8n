# ── Memorystore for Redis ─────────────────────────────────────────────────────
# n8n uses Redis as the queue backend distributing executions across workers and
# coordinating multi-main.
#
# create_redis_instance gates the instance as a single unit (D4): with
# create_redis_instance = false the caller supplies an external host and
# optional port/TLS/username/password (redis_host, redis_port,
# redis_tls_enabled, redis_username, redis_password /
# redis_password_secret_ref; see locals.tf's effective_redis_* locals and
# n8n.tf's kubernetes_secret.n8n_redis) instead of any resource in this file.
#
# BASIC tier (no replica) and REDIS_7_2 by default. AUTH and in-transit
# encryption are both off by default (redis_auth_enabled,
# redis_transit_encryption_enabled); if flipped on, the KEDA worker trigger
# (keda.tf) needs a TriggerAuthentication CRD, which locals.tf's
# manage_redis_trigger_auth already accounts for.

# Curated Checkov exceptions for this instance:
#
# CKV_GCP_97 (in-transit encryption): transit_encryption_mode defaults to
# DISABLED, matching n8n's own default unencrypted Redis client behavior over
# a private VPC connection; redis_transit_encryption_enabled lets an operator
# turn this on without any code change (see the file-level comment and
# manage_redis_trigger_auth in locals.tf, which already accounts for the
# resulting KEDA TriggerAuthentication requirement).
#
# CKV_GCP_95 (AUTH): auth_enabled defaults to false, matching n8n's own
# default unauthenticated Redis client behavior; redis_auth_enabled lets an
# operator turn this on the same way as transit encryption above.
resource "google_redis_instance" "n8n" {
  count = var.create_redis_instance ? 1 : 0

  # checkov:skip=CKV_GCP_97: intentional, opt-in via redis_transit_encryption_enabled, see resource comment above.
  # checkov:skip=CKV_GCP_95: intentional, opt-in via redis_auth_enabled, see resource comment above.

  name           = "${local.name_prefix}-redis"
  project        = var.project_id
  region         = var.gcp_region
  tier           = var.redis_tier
  memory_size_gb = var.redis_memory_size_gb
  redis_version  = var.redis_version

  authorized_network      = local.effective_network_id
  connect_mode            = "PRIVATE_SERVICE_ACCESS"
  auth_enabled            = var.redis_auth_enabled
  transit_encryption_mode = var.redis_transit_encryption_enabled ? "SERVER_AUTHENTICATION" : "DISABLED"
  customer_managed_key    = local.effective_redis_kms_key_id

  labels = local.gcp_labels

  # Opt-in RDB persistence (redis_persistence_enabled): Memorystore's own
  # automatic last-snapshot recovery, not a numbered backup-retention count.
  # Omitted entirely when disabled, leaving persistence off (Memorystore's own
  # default) rather than emitting an explicit DISABLED block.
  dynamic "persistence_config" {
    for_each = var.redis_persistence_enabled ? [1] : []
    content {
      persistence_mode        = "RDB"
      rdb_snapshot_period     = var.redis_rdb_snapshot_period
      rdb_snapshot_start_time = var.redis_rdb_snapshot_start_time
    }
  }

  # Depending on the time_sleep (not the connection directly) also delays the
  # peering's destruction until after this instance is gone; see network.tf.
  # Also wait for the module-created key's IAM grant (kms.tf).
  depends_on = [
    time_sleep.wait_for_psa_cleanup,
    google_kms_crypto_key_iam_member.redis,
  ]
}
