# ── Google Secret Manager access ──────────────────────────────────────────────
# Opt-in (D7): grants the n8n Workload Identity Google service account
# roles/secretmanager.secretAccessor scoped to each supplied secret resource
# ID, never project-wide access. n8n_secret_manager_secret_ids is a required,
# non-empty, wildcard-free allow-list (variables.tf), so no apply can grant
# broader access than the caller explicitly listed.
#
# This only grants the underlying GCP IAM a Google Secret Manager vault
# provider needs at runtime; configuring that vault-provider connection itself
# (n8n Settings > External Secrets) remains an in-product operator action the
# module does not automate. n8n's generic External Secrets feature switch and
# update interval (n8n_external_secrets_enabled / _update_interval) are
# independent and wired in n8n.tf.

resource "google_secret_manager_secret_iam_member" "n8n" {
  for_each = var.n8n_secret_manager_enabled ? toset(var.n8n_secret_manager_secret_ids) : toset([])

  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.n8n.email}"
}
