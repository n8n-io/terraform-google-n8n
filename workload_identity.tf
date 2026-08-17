# ── Workload Identity for pod identity ────────────────────────────────────────
# The n8n pods run as a Kubernetes ServiceAccount that is bound to this Google
# service account, so the workload authenticates to GCP APIs (Cloud SQL, etc.)
# without static keys. The KSA -> GSA binding is expressed here; the KSA
# annotation and the cluster's workload_identity_config are set in gke.tf and
# n8n.tf. Storage stays on HMAC keys, not Workload Identity, because the n8n S3
# driver needs static credentials.

resource "google_service_account" "n8n" {
  # "-wi" (workload identity), not "-n8n": local.name_prefix already ends in
  # -n8n and a -n8n suffix would produce the redundant <prefix>-n8n-n8n id the
  # friendly_name_prefix validator warns against.
  account_id   = substr("${local.name_prefix}-wi", 0, 30)
  project      = var.project_id
  display_name = "n8n workload identity (${local.name_prefix})"
}

# Let the Kubernetes ServiceAccount impersonate the Google service account.
# Uses the effective (managed or existing-cluster) Workload Identity pool and
# namespace (locals.tf / D3, D4) so the binding is correct for a cross-project
# existing GKE cluster and for an existing (create_namespace = false) namespace.
# local.n8n_service_account_name (not var.n8n_kube_svc_account directly) so the
# binding follows whichever KSA is effective when n8n_image_pull_secrets moves
# ServiceAccount ownership from the chart to the module (see locals.tf).
resource "google_service_account_iam_member" "n8n_workload_identity" {
  service_account_id = google_service_account.n8n.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.effective_gke_workload_identity_pool}[${local.effective_namespace}/${local.n8n_service_account_name}]"
}

# Cloud SQL client role so the workload can reach the database. Cloud-SQL-only
# IAM (D4): gated by create_postgres_instance alongside the instance itself in
# cloudsql.tf; an external database's IAM is entirely the caller's concern.
resource "google_project_iam_member" "n8n_cloudsql_client" {
  count = var.create_postgres_instance ? 1 : 0

  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.n8n.email}"
}
