# ── GCS binary storage via HMAC keys ──────────────────────────────────────────
# n8n's binary-data driver is S3-compatible and needs STATIC credentials, so it
# cannot use Workload Identity for storage; a dedicated service account gets an
# HMAC key that n8n uses as S3 access-key/secret against the GCS S3-compatible
# endpoint.
#
# NOTE: HMAC-key creation is blocked by the
# iam.disableServiceAccountKeyCreation org policy. That policy must be disabled
# on the project (or an exception granted) or this apply fails, UNLESS you bring
# your own key (see the BYO-HMAC locals below).

locals {
  # BYO HMAC: orgs that cannot relax
  # iam.disableServiceAccountKeyCreation can create the service account + HMAC
  # key out of band and pass the credentials in, so this module never calls
  # google_storage_hmac_key. Setting gcs_hmac_service_account_email switches the
  # module into BYO mode: it stops creating the service account and the key, and
  # instead grants the supplied SA access to the (still module-created) bucket.
  manage_hmac_key = var.gcs_hmac_service_account_email == ""

  hmac_sa_email  = local.manage_hmac_key ? google_service_account.storage[0].email : var.gcs_hmac_service_account_email
  hmac_access_id = local.manage_hmac_key ? google_storage_hmac_key.n8n[0].access_id : var.gcs_hmac_access_id

  # The k8s Secret holding the HMAC secret access key that n8n's S3 driver reads
  # (s3.auth.secretAccessKeySecret). When the caller points at an existing Secret
  # (gcs_hmac_secret_name) the module uses it as-is; otherwise the module creates
  # n8n-s3-secret from the created key's secret (managed) or the supplied raw
  # secret (BYO with a plaintext gcs_hmac_secret).
  manage_s3_secret = var.gcs_hmac_secret_name == ""
  s3_secret_name   = local.manage_s3_secret ? kubernetes_secret.n8n_s3[0].metadata[0].name : var.gcs_hmac_secret_name
  s3_secret_value  = local.manage_hmac_key ? try(google_storage_hmac_key.n8n[0].secret, null) : var.gcs_hmac_secret
}

resource "google_service_account" "storage" {
  count = local.manage_hmac_key ? 1 : 0

  account_id   = substr("${local.cluster_name}-store", 0, 30)
  project      = var.project_id
  display_name = "n8n GCS binary storage access (${local.cluster_name})"
}

resource "google_storage_bucket" "n8n" {
  name                        = "${var.project_id}-n8n-${local.cluster_name}"
  project                     = var.project_id
  location                    = var.gcs_location
  uniform_bucket_level_access = true
  force_destroy               = var.gcs_force_destroy
  labels                      = local.gcp_labels

  versioning {
    enabled = true
  }
}

resource "google_storage_bucket_iam_member" "storage" {
  bucket = google_storage_bucket.n8n.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.hmac_sa_email}"
}

# S3-compatible static credentials for the n8n binary-data driver.
# Blocked by iam.disableServiceAccountKeyCreation; either the module clears that
# via org_policy.tf (manage_sa_key_org_policy = true), it is cleared out-of-band,
# or the caller brings their own key (gcs_hmac_service_account_email set) and this
# resource is skipped entirely.
resource "google_storage_hmac_key" "n8n" {
  count = local.manage_hmac_key ? 1 : 0

  service_account_email = google_service_account.storage[0].email
  project               = var.project_id

  depends_on = [google_org_policy_policy.disable_sa_key_creation]
}

# BYO-HMAC completeness gate: if you switch to BYO mode (supply an SA email) you
# must also supply the access ID and a secret (raw or via an existing Secret).
check "byo_hmac_credentials_complete" {
  assert {
    condition = local.manage_hmac_key || (
      var.gcs_hmac_access_id != "" &&
      (var.gcs_hmac_secret != "" || var.gcs_hmac_secret_name != "")
    )
    error_message = "gcs_hmac_service_account_email is set (BYO HMAC mode), so gcs_hmac_access_id and either gcs_hmac_secret or gcs_hmac_secret_name are also required."
  }
}
