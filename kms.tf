# ── Shared Cloud KMS key ring ─────────────────────────────────────────────────
# Hosts every effective module-created CMEK key. A key request is effective only
# when the module also owns the service it protects; ignored customer-managed
# service inputs must not leave protected KMS resources behind.

resource "google_kms_key_ring" "n8n" {
  count = var.create_kms_key_ring && local.create_any_kms_key ? 1 : 0

  name     = "${local.name_prefix}-keyring"
  project  = var.project_id
  location = local.effective_kms_key_ring_location
}

# The stable IAM member addresses below need this project's number, while the
# service-identity resources provide the creation-order dependency.
data "google_project" "n8n" {
  project_id = var.project_id
}

locals {
  create_postgres_kms_key = var.create_postgres_instance && var.create_postgres_kms_key
  create_redis_kms_key    = var.create_redis_instance && var.create_redis_kms_key
  create_gcs_kms_key      = var.create_gcs_bucket && var.create_gcs_kms_key
  create_gke_kms_key      = var.create_gke && var.create_gke_kms_key
  create_any_kms_key      = local.create_postgres_kms_key || local.create_redis_kms_key || local.create_gcs_kms_key || local.create_gke_kms_key

  # CKV_GCP_43 (Checkov): rotate every module-created CMEK key within 90 days.
  # Google recommends this as a default hygiene practice; rotation only
  # re-wraps the key material, so it does not require any n8n-side change or
  # re-encrypt the underlying Cloud SQL/Memorystore/GCS data.
  kms_rotation_period = "7776000s"

  # Cloud Storage uses "europe" for an EU multi-region KMS key; all other
  # bucket location codes match their KMS location after lower-casing.
  gcs_kms_location = lower(var.gcs_location) == "eu" ? "europe" : lower(var.gcs_location)

  # A GCS-only ring follows the bucket. Regional Cloud SQL and Memorystore
  # require gcp_region, and cross-service validation prevents an incompatible
  # bucket location from sharing that regional ring.
  default_kms_key_ring_location   = local.create_gcs_kms_key && !local.create_postgres_kms_key && !local.create_redis_kms_key ? local.gcs_kms_location : var.gcp_region
  effective_kms_key_ring_location = coalesce(var.kms_key_ring_location, local.default_kms_key_ring_location)
  effective_kms_key_ring_id       = var.create_kms_key_ring && local.create_any_kms_key ? google_kms_key_ring.n8n[0].id : var.existing_kms_key_ring_id
}

# ── Cloud SQL customer-managed encryption key ─────────────────────────────────
# create_postgres_kms_key creates a key in the shared ring above and scopes IAM
# to it; existing_postgres_kms_key_id references an already-existing key and
# grants no IAM (the caller owns that key's access out of band). Both are
# ignored when create_postgres_instance = false (checks.tf emits the
# ignored-input diagnostic).

# Google creates service agents lazily. Materialize the Cloud SQL identity
# before granting key IAM so a fresh project does not fail with "service
# account does not exist" on its first CMEK apply.
resource "google_project_service_identity" "postgres" {
  provider = google-beta
  count    = local.create_postgres_kms_key ? 1 : 0

  project = var.project_id
  service = "sqladmin.googleapis.com"
}

resource "google_kms_crypto_key" "postgres" {
  count = local.create_postgres_kms_key ? 1 : 0

  name            = "${local.name_prefix}-pg-key"
  key_ring        = local.effective_kms_key_ring_id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = local.kms_rotation_period
  labels          = local.gcp_labels

  lifecycle {
    prevent_destroy = true
  }
}

# Cloud SQL's per-project service agent must be able to use a module-created
# key; an existing key's IAM is the caller's responsibility (D4: "Required
# Google-managed service-agent IAM bindings are created only for keys the
# module is explicitly authorized to bind").
resource "google_kms_crypto_key_iam_member" "postgres" {
  count = local.create_postgres_kms_key ? 1 : 0

  crypto_key_id = google_kms_crypto_key.postgres[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.n8n.number}@gcp-sa-cloud-sql.iam.gserviceaccount.com"

  depends_on = [google_project_service_identity.postgres]
}

locals {
  effective_postgres_kms_key_id = var.create_postgres_instance ? (local.create_postgres_kms_key ? google_kms_crypto_key.postgres[0].id : var.existing_postgres_kms_key_id) : null
}

# ── Memorystore customer-managed encryption key ───────────────────────────────
# Same create-or-reference contract as Cloud SQL above. Memorystore does not
# support enabling CMEK on an already-created instance, so this key is only
# ever read at instance creation (memorystore.tf).

resource "google_project_service_identity" "redis" {
  provider = google-beta
  count    = local.create_redis_kms_key ? 1 : 0

  project = var.project_id
  service = "redis.googleapis.com"
}

resource "google_kms_crypto_key" "redis" {
  count = local.create_redis_kms_key ? 1 : 0

  name            = "${local.name_prefix}-redis-key"
  key_ring        = local.effective_kms_key_ring_id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = local.kms_rotation_period
  labels          = local.gcp_labels

  lifecycle {
    prevent_destroy = true
  }
}

# Memorystore's per-project service agent must be able to use a module-created
# key; an existing key's IAM is the caller's responsibility (D4).
resource "google_kms_crypto_key_iam_member" "redis" {
  count = local.create_redis_kms_key ? 1 : 0

  crypto_key_id = google_kms_crypto_key.redis[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.n8n.number}@cloud-redis.iam.gserviceaccount.com"

  depends_on = [google_project_service_identity.redis]
}

locals {
  effective_redis_kms_key_id = var.create_redis_instance ? (local.create_redis_kms_key ? google_kms_crypto_key.redis[0].id : var.existing_redis_kms_key_id) : null
}

# ── GCS customer-managed encryption key ───────────────────────────────────────
# Same create-or-reference contract as Cloud SQL and Memorystore above. Only
# takes effect for a module-managed bucket at creation (gcs.tf's dynamic
# "encryption" block); an existing bucket's encryption is never mutated.

resource "google_project_service_identity" "gcs" {
  provider = google-beta
  count    = local.create_gcs_kms_key ? 1 : 0

  project = var.project_id
  service = "storage.googleapis.com"
}

resource "google_kms_crypto_key" "gcs" {
  count = local.create_gcs_kms_key ? 1 : 0

  name            = "${local.name_prefix}-gcs-key"
  key_ring        = local.effective_kms_key_ring_id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = local.kms_rotation_period
  labels          = local.gcp_labels

  lifecycle {
    prevent_destroy = true
  }
}

# Cloud Storage's per-project service agent must be able to use a
# module-created key; an existing key's IAM is the caller's responsibility
# (D4).
resource "google_kms_crypto_key_iam_member" "gcs" {
  count = local.create_gcs_kms_key ? 1 : 0

  crypto_key_id = google_kms_crypto_key.gcs[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.n8n.number}@gs-project-accounts.iam.gserviceaccount.com"

  depends_on = [google_project_service_identity.gcs]
}

locals {
  effective_gcs_kms_key_id = var.create_gcs_bucket ? (local.create_gcs_kms_key ? google_kms_crypto_key.gcs[0].id : var.existing_gcs_kms_key_id) : null
}

# ── GKE customer-managed encryption (Cloud KMS) ───────────────────────────────
# Same create-or-reference contract as Cloud SQL, Memorystore, and GCS above
# (D4): create_gke_kms_key creates a key in the shared ring and configures the
# module-managed cluster's application-layer secrets encryption
# (database_encryption in gke.tf) to use it; existing_gke_kms_key_id
# references an already-existing key instead. Leaving both unset keeps GKE's
# default Google-managed etcd encryption. Only takes effect for a
# module-managed cluster (create_gke = true); the key must be regional and
# share gcp_region with the cluster, same as Cloud SQL/Memorystore above.

# GKE's own service agent (container-engine-robot) must exist before it can
# be granted key IAM; same lazy-materialization rationale as Cloud SQL/
# Memorystore/GCS above.
resource "google_project_service_identity" "gke" {
  provider = google-beta
  count    = local.create_gke_kms_key ? 1 : 0

  project = var.project_id
  service = "container.googleapis.com"
}

resource "google_kms_crypto_key" "gke" {
  count = local.create_gke_kms_key ? 1 : 0

  name            = "${local.name_prefix}-gke-key"
  key_ring        = local.effective_kms_key_ring_id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = local.kms_rotation_period
  labels          = local.gcp_labels

  lifecycle {
    prevent_destroy = true
  }
}

# GKE's per-project service agent must be able to use a module-created key;
# an existing key's IAM is the caller's responsibility (D4).
resource "google_kms_crypto_key_iam_member" "gke" {
  count = local.create_gke_kms_key ? 1 : 0

  crypto_key_id = google_kms_crypto_key.gke[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.n8n.number}@container-engine-robot.iam.gserviceaccount.com"

  depends_on = [google_project_service_identity.gke]
}

locals {
  effective_gke_kms_key_id = var.create_gke ? (local.create_gke_kms_key ? google_kms_crypto_key.gke[0].id : var.existing_gke_kms_key_id) : null
}
