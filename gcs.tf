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
#
# create_gcs_bucket gates the bucket alone (D4). HMAC identity ownership
# (manage_hmac_key, driven by gcs_hmac_service_account_email) is an
# independent axis: the module can create the bucket but reference an
# existing HMAC identity, or reference an existing bucket but still create
# the HMAC identity/key, granting only bucket-scoped IAM to whichever
# identity is effective. See locals.tf's effective_gcs_bucket_name.

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

  account_id   = substr("${local.name_prefix}-store", 0, 30)
  project      = var.project_id
  display_name = "n8n GCS binary storage access (${local.name_prefix})"
}

# A dedicated access-log bucket for the binary-data bucket below. Short-lived:
# access logs are useful for near-term investigation, not long-term
# retention, so objects expire quickly to keep storage cost negligible.
#
# CKV_GCP_62 exception: a log bucket does not log access to itself; nothing
# else in this module writes to it, and pointing it at another bucket would
# just move this same finding one bucket over.
resource "google_storage_bucket" "n8n_access_logs" {
  count = var.create_gcs_bucket ? 1 : 0

  # checkov:skip=CKV_GCP_62: intentional design choice, see resource comment above.

  name                        = "${var.project_id}-n8n-${var.friendly_name_prefix}-logs"
  project                     = var.project_id
  location                    = var.gcs_location
  uniform_bucket_level_access = true
  force_destroy               = var.gcs_force_destroy
  labels                      = local.gcp_labels
  public_access_prevention    = "enforced"

  # CKV_GCP_78: cheap to keep on even for a short-lived log bucket.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30
    }
  }
}

resource "google_storage_bucket" "n8n" {
  count = var.create_gcs_bucket ? 1 : 0

  # Keep the project-id prefix (not local.name_prefix) for global bucket-name
  # uniqueness: <project_id>-n8n-<friendly_name_prefix>.
  name                        = "${var.project_id}-n8n-${var.friendly_name_prefix}"
  project                     = var.project_id
  location                    = var.gcs_location
  uniform_bucket_level_access = true
  force_destroy               = var.gcs_force_destroy
  labels                      = local.gcp_labels

  # Belt and braces on top of uniform bucket-level access: this bucket only
  # ever holds private n8n binary data, so hard-block any public grant.
  public_access_prevention = "enforced"

  versioning {
    enabled = true
  }

  # CKV_GCP_62: log every access to the log bucket declared above.
  logging {
    log_bucket = google_storage_bucket.n8n_access_logs[0].name
  }

  # Keep versioning bounded: n8n rewrites binary-data objects constantly, so
  # noncurrent versions accumulate fast and are pure storage cost. Retain the
  # three most recent noncurrent versions and delete older ones.
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      with_state         = "ARCHIVED"
      num_newer_versions = 3
    }
  }

  # Customer-managed encryption (kms.tf's effective_gcs_kms_key_id) only ever
  # takes effect here, at bucket creation; an existing bucket's encryption is
  # the caller's responsibility and is never mutated (D4).
  dynamic "encryption" {
    for_each = local.effective_gcs_kms_key_id != null ? [1] : []
    content {
      default_kms_key_name = local.effective_gcs_kms_key_id
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs]
}

# Bucket-scoped, least-privilege IAM for the effective HMAC identity, granted
# regardless of which side (bucket, HMAC identity, or both) is module-managed.
resource "google_storage_bucket_iam_member" "storage" {
  bucket = local.effective_gcs_bucket_name
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

# BYO-HMAC completeness is enforced at plan time by cross-variable validation
# blocks on the gcs_hmac_* variables (variables_gcp.tf): BYO mode requires the
# access ID plus a secret (raw or via an existing Secret), and the secret
# inputs are rejected outside BYO mode.
