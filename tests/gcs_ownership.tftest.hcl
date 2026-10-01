# Plan-time tests for the section 7 GCS bucket, HMAC, and encryption
# ownership: count-gating the bucket independently from the HMAC service
# account, bucket IAM, and HMAC key (create_gcs_bucket), every
# bucket/HMAC-identity ownership combination, the module-created/existing
# Cloud KMS key contract, and the opposite-path diagnostics.

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

# ── Defaults create every managed GCS resource ────────────────────────────────

run "defaults_create_managed_gcs_resources" {
  command = plan

  assert {
    condition     = length(google_storage_bucket.n8n) == 1
    error_message = "create_gcs_bucket defaults to true and must create the bucket."
  }

  assert {
    condition     = length(google_service_account.storage) == 1
    error_message = "gcs_hmac_service_account_email defaults to empty (managed HMAC identity) and must create the storage service account."
  }

  assert {
    condition     = length(google_storage_hmac_key.n8n) == 1
    error_message = "The managed HMAC identity path must create the HMAC key."
  }

  assert {
    condition     = google_storage_bucket_iam_member.storage.bucket == "test-project-n8n-test"
    error_message = "The bucket IAM member must reference the module-created bucket name."
  }

  assert {
    condition     = output.gcs_kms_key_id == null
    error_message = "gcs_kms_key_id output must be null when no KMS key is configured."
  }

  # CKV_GCP_62: the binary-data bucket must always log access to a dedicated,
  # separate access-log bucket (see the security baseline report).
  assert {
    condition     = length(google_storage_bucket.n8n_access_logs) == 1
    error_message = "create_gcs_bucket defaults to true and must create the access-log bucket."
  }

  assert {
    condition     = google_storage_bucket.n8n[0].logging[0].log_bucket == google_storage_bucket.n8n_access_logs[0].name
    error_message = "The binary-data bucket must log access to the dedicated access-log bucket."
  }

  assert {
    condition = (
      google_storage_bucket_iam_member.n8n_access_logs[0].bucket == google_storage_bucket.n8n_access_logs[0].name &&
      google_storage_bucket_iam_member.n8n_access_logs[0].role == "roles/storage.objectCreator" &&
      google_storage_bucket_iam_member.n8n_access_logs[0].member == "group:cloud-storage-analytics@google.com"
    )
    error_message = "Cloud Storage's logging identity must have objectCreator access scoped to the log destination bucket."
  }

  assert {
    condition     = google_storage_bucket.n8n_access_logs[0].versioning[0].enabled == true
    error_message = "The access-log bucket must also enable versioning (CKV_GCP_78)."
  }
}

# ── Existing bucket, managed HMAC identity ────────────────────────────────────

run "existing_bucket_with_managed_hmac_identity_creates_no_bucket" {
  command = plan

  variables {
    create_gcs_bucket        = false
    existing_gcs_bucket_name = "external-n8n-bucket"
  }

  assert {
    condition     = length(google_storage_bucket.n8n) == 0
    error_message = "create_gcs_bucket = false must not create a bucket."
  }

  assert {
    condition     = length(google_service_account.storage) == 1
    error_message = "Bucket ownership is independent of HMAC identity ownership; the managed HMAC identity must still be created."
  }

  assert {
    condition     = length(google_storage_hmac_key.n8n) == 1
    error_message = "The managed HMAC key must still be created for an existing bucket."
  }

  assert {
    condition     = google_storage_bucket_iam_member.storage.bucket == "external-n8n-bucket"
    error_message = "The bucket IAM member must reference the supplied existing bucket name."
  }

  assert {
    condition     = output.gcs_bucket_name == "external-n8n-bucket"
    error_message = "gcs_bucket_name output must resolve to the supplied existing bucket."
  }

  assert {
    condition     = length(google_storage_bucket.n8n_access_logs) == 0
    error_message = "create_gcs_bucket = false must not create the module-managed access-log bucket; an existing bucket's own access logging is the caller's responsibility."
  }

  assert {
    condition     = length(google_storage_bucket_iam_member.n8n_access_logs) == 0
    error_message = "An existing bucket must receive no module-managed logging IAM grant."
  }
}

# ── Existing bucket, BYO HMAC identity: fully customer-managed data plane ───

run "existing_bucket_with_byo_hmac_creates_no_gcs_resources" {
  command = plan

  variables {
    create_gcs_bucket              = false
    existing_gcs_bucket_name       = "external-n8n-bucket"
    gcs_hmac_service_account_email = "byo-hmac@test-project.iam.gserviceaccount.com"
    gcs_hmac_access_id             = "GOOG1EXAMPLEACCESSID"
    gcs_hmac_secret_name           = "n8n-s3-external"
  }

  assert {
    condition     = length(google_storage_bucket.n8n) == 0
    error_message = "create_gcs_bucket = false must not create a bucket."
  }

  assert {
    condition     = length(google_service_account.storage) == 0
    error_message = "BYO HMAC mode must not create the storage service account."
  }

  assert {
    condition     = length(google_storage_hmac_key.n8n) == 0
    error_message = "BYO HMAC mode must not create an HMAC key."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_s3) == 0
    error_message = "An existing HMAC-secret Secret reference must not create the module-managed Secret."
  }

  assert {
    condition     = google_storage_bucket_iam_member.storage.member == "serviceAccount:byo-hmac@test-project.iam.gserviceaccount.com"
    error_message = "The only resource created in this fully customer-managed combination is the scoped bucket IAM grant to the caller-supplied identity."
  }
}

# ── Bucket and HMAC ownership differ (module-managed bucket, BYO HMAC) ──────

run "managed_bucket_with_byo_hmac_creates_only_bucket_and_iam" {
  command = plan

  variables {
    gcs_hmac_service_account_email = "byo-hmac@test-project.iam.gserviceaccount.com"
    gcs_hmac_access_id             = "GOOG1EXAMPLEACCESSID"
    gcs_hmac_secret_name           = "n8n-s3-external"
  }

  assert {
    condition     = length(google_storage_bucket.n8n) == 1
    error_message = "create_gcs_bucket defaults to true and must still create the bucket."
  }

  assert {
    condition     = length(google_service_account.storage) == 0
    error_message = "BYO HMAC mode must not create the storage service account, even for a module-managed bucket."
  }

  assert {
    condition     = length(google_storage_hmac_key.n8n) == 0
    error_message = "BYO HMAC mode must not create an HMAC key, even for a module-managed bucket."
  }

  assert {
    condition     = length(google_storage_bucket_iam_member.n8n_access_logs) == 1
    error_message = "A managed bucket needs log-delivery IAM even when the caller supplies the HMAC identity."
  }
}

# ── Cloud KMS create-or-reference ─────────────────────────────────────────────

run "module_created_gcs_key_wires_key_ring_and_iam" {
  command = plan

  variables {
    create_kms_key_ring = true
    create_gcs_kms_key  = true
  }

  assert {
    condition     = length(google_kms_key_ring.n8n) == 1
    error_message = "create_kms_key_ring = true must create the shared key ring."
  }

  assert {
    condition     = length(google_kms_crypto_key.gcs) == 1
    error_message = "create_gcs_kms_key = true must create the GCS CryptoKey."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.gcs) == 1
    error_message = "A module-created key must grant the Cloud Storage service agent IAM."
  }

  assert {
    condition     = google_kms_key_ring.n8n[0].location == "europe"
    error_message = "A GCS-only module-created key ring must map the default EU bucket location to the compatible KMS europe multi-region."
  }

  assert {
    condition = (
      length(google_project_service_identity.gcs) == 1 &&
      google_project_service_identity.gcs[0].project == "test-project" &&
      google_project_service_identity.gcs[0].service == "storage.googleapis.com"
    )
    error_message = "A module-created GCS key must materialize the target project's Cloud Storage service agent before granting IAM."
  }

  # CKV_GCP_43: every module-created CMEK key rotates within 90 days.
  assert {
    condition     = google_kms_crypto_key.gcs[0].rotation_period == "7776000s"
    error_message = "A module-created GCS CryptoKey must rotate every 90 days."
  }

  assert {
    condition = (
      try(google_kms_crypto_key.gcs[0].labels["managed_by"], null) == "terraform" &&
      try(google_kms_crypto_key.gcs[0].labels["app"], null) == "n8n"
    )
    error_message = "A module-created GCS CryptoKey must carry the module's standard labels (local.gcp_labels)."
  }
}

run "shared_ring_rejects_incompatible_regional_and_multi_region_services" {
  command = plan

  variables {
    create_kms_key_ring     = true
    create_postgres_kms_key = true
    create_gcs_kms_key      = true
  }

  expect_failures = [var.kms_key_ring_location]
}

run "existing_gcs_key_creates_no_key_or_iam" {
  command = plan

  variables {
    existing_gcs_kms_key_id = "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/gcs"
  }

  assert {
    condition     = length(google_kms_key_ring.n8n) == 0
    error_message = "An existing key must not require a module-managed key ring."
  }

  assert {
    condition     = length(google_kms_crypto_key.gcs) == 0
    error_message = "An existing key must not be created."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.gcs) == 0
    error_message = "An existing key must get no module-managed IAM grant."
  }

  assert {
    condition     = output.gcs_kms_key_id == "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/gcs"
    error_message = "gcs_kms_key_id output must resolve to the supplied existing key."
  }
}

run "create_and_existing_gcs_key_are_mutually_exclusive" {
  command = plan

  variables {
    create_gcs_kms_key      = true
    existing_gcs_kms_key_id = "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/gcs"
  }

  expect_failures = [var.create_gcs_kms_key]
}

run "module_created_gcs_key_without_ring_reference_fails" {
  command = plan

  variables {
    create_gcs_kms_key = true
    # create_kms_key_ring left false and existing_kms_key_ring_id unset.
  }

  expect_failures = [var.existing_kms_key_ring_id]
}

run "gcs_kms_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_gcs_bucket        = false
    existing_gcs_bucket_name = "external-n8n-bucket"
    create_gcs_kms_key       = true
    create_kms_key_ring      = true
  }

  expect_failures = [check.gcs_kms_ignored_when_existing]

  assert {
    condition = (
      length(google_kms_key_ring.n8n) == 0 &&
      length(google_kms_crypto_key.gcs) == 0 &&
      length(google_kms_crypto_key_iam_member.gcs) == 0
    )
    error_message = "Ignored GCS CMEK inputs must not create a key ring, key, or IAM binding for an existing bucket."
  }
}

# ── Missing existing-bucket reference fails validation ───────────────────────

run "existing_bucket_without_name_fails_validation" {
  command = plan

  variables {
    create_gcs_bucket = false
  }

  expect_failures = [var.existing_gcs_bucket_name]
}
