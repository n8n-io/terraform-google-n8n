# Plan-time tests for the section 8 namespace, Kubernetes Secret, and
# Workload Identity ownership: count-gating the namespace (create_namespace),
# every existing-Secret reference (license, core, PostgreSQL, Redis, GCS), the
# core-Secret/separate-license-Secret contract, and the effective Workload
# Identity binding for managed and existing GKE/namespace combinations.

# mock_data "google_container_cluster" defaults to a compatible cluster
# (VPC-native, Workload Identity enabled); the existing-GKE cross-project
# Workload Identity test overrides workload_identity_config.
mock_provider "google" {
  mock_data "google_container_cluster" {
    defaults = {
      endpoint        = "10.0.0.2"
      networking_mode = "VPC_NATIVE"
      master_auth = [{
        client_certificate        = ""
        client_certificate_config = []
        client_key                = ""
        cluster_ca_certificate    = "ZmFrZS1jYQ=="
      }]
      workload_identity_config = [{ workload_pool = "test-project.svc.id.goog" }]
    }
  }
}
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

# ── Namespace ownership ───────────────────────────────────────────────────────

run "defaults_create_managed_namespace" {
  command = plan

  assert {
    condition     = length(kubernetes_namespace.n8n) == 1
    error_message = "create_namespace defaults to true and must create the namespace."
  }

  assert {
    condition     = kubernetes_namespace.n8n[0].metadata[0].name == "n8n"
    error_message = "The managed namespace must be named after n8n_kube_namespace."
  }
}

run "existing_namespace_creates_no_namespace_resource" {
  command = plan

  variables {
    create_namespace   = false
    n8n_kube_namespace = "existing-n8n"
  }

  assert {
    condition     = length(kubernetes_namespace.n8n) == 0
    error_message = "create_namespace = false must not create a namespace."
  }

  assert {
    condition     = output.n8n_kube_namespace == "existing-n8n"
    error_message = "n8n_kube_namespace output must resolve to the supplied existing namespace name."
  }

  assert {
    condition     = kubernetes_secret.n8n[0].metadata[0].namespace == "existing-n8n"
    error_message = "Namespaced resources must target the existing namespace, not a resource-derived reference."
  }

  assert {
    condition     = helm_release.n8n.namespace == "existing-n8n"
    error_message = "The n8n Helm release must target the existing namespace."
  }

  assert {
    condition     = google_service_account_iam_member.n8n_workload_identity.member == "serviceAccount:test-project.svc.id.goog[existing-n8n/n8n]"
    error_message = "The Workload Identity binding must target the existing namespace."
  }
}

# ── License Secret reference ──────────────────────────────────────────────────

run "license_key_secret_ref_wires_into_helm_values" {
  command = plan

  variables {
    n8n_license_key = null
    n8n_license_key_secret_ref = {
      name = "n8n-license"
      key  = "activation-key"
    }
  }

  assert {
    condition     = helm_release.n8n.namespace == "n8n"
    error_message = "A license Secret reference must still plan cleanly."
  }
}

run "license_key_and_secret_ref_are_mutually_exclusive" {
  command = plan

  variables {
    n8n_license_key = "direct-key"
    n8n_license_key_secret_ref = {
      name = "n8n-license"
    }
  }

  expect_failures = [var.n8n_license_key_secret_ref]
}

run "license_key_missing_source_fails_validation" {
  command = plan

  variables {
    n8n_license_key = null
    # n8n_license_key_secret_ref intentionally unset
  }

  expect_failures = [var.n8n_license_key_secret_ref]
}

# ── Core Secret reference ─────────────────────────────────────────────────────

run "existing_core_secret_creates_no_managed_secret_or_key" {
  command = plan

  variables {
    existing_n8n_core_secret_name = "existing-core-secrets"
    n8n_license_key               = null
    n8n_license_key_secret_ref = {
      name = "n8n-license"
    }
  }

  assert {
    condition     = length(kubernetes_secret.n8n) == 0
    error_message = "An existing core Secret must not create the module-managed core Secret."
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "An existing core Secret must not generate an encryption key that is never used."
  }

  assert {
    condition     = output.n8n_encryption_key == null
    error_message = "n8n_encryption_key output must be null when an existing core Secret is supplied."
  }
}

run "existing_core_secret_without_license_secret_ref_fails_validation" {
  command = plan

  variables {
    existing_n8n_core_secret_name = "existing-core-secrets"
    # n8n_license_key_secret_ref intentionally unset; n8n_license_key (default var) still set.
  }

  expect_failures = [var.existing_n8n_core_secret_name]
}

# ── Direct encryption-key continuity ──────────────────────────────────────────

run "default_generates_encryption_key" {
  command = plan

  assert {
    condition     = length(random_id.n8n_encryption_key) == 1
    error_message = "With no direct key and no existing core Secret, the module must generate the encryption key."
  }

  assert {
    condition     = contains(keys(kubernetes_secret.n8n[0].data), "N8N_ENCRYPTION_KEY")
    error_message = "The managed core Secret must carry a generated encryption key."
  }
}

run "direct_encryption_key_replaces_generation" {
  command = plan

  variables {
    n8n_encryption_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "A supplied direct key must replace generation; no random key should be created."
  }

  assert {
    condition     = kubernetes_secret.n8n[0].data["N8N_ENCRYPTION_KEY"] == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "The managed core Secret must carry the exact supplied key, unchanged."
  }

  assert {
    condition     = output.n8n_encryption_key == "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    error_message = "The sensitive output must return the supplied key."
  }
}

run "encryption_key_ignored_when_existing_core_secret_unread" {
  command = plan

  variables {
    existing_n8n_core_secret_name = "existing-core-secrets"
    n8n_license_key               = null
    n8n_license_key_secret_ref = {
      name = "n8n-license"
    }
  }

  assert {
    condition     = length(random_id.n8n_encryption_key) == 0
    error_message = "An unread external core Secret must never trigger key generation."
  }

  assert {
    condition     = output.n8n_encryption_key == null
    error_message = "The sensitive output must stay null for an unread external core Secret."
  }
}

run "encryption_key_rejects_malformed_value" {
  command = plan

  variables {
    n8n_encryption_key = "not-a-valid-hex-key"
  }

  expect_failures = [var.n8n_encryption_key]
}

run "encryption_key_and_existing_core_secret_are_mutually_exclusive" {
  command = plan

  variables {
    n8n_encryption_key            = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    existing_n8n_core_secret_name = "existing-core-secrets"
    n8n_license_key               = null
    n8n_license_key_secret_ref = {
      name = "n8n-license"
    }
  }

  expect_failures = [var.n8n_encryption_key]
}

# ── Existing Secret references (PostgreSQL, Redis, GCS) plan cleanly together ─
# with an existing namespace and core Secret, proving every credential Secret
# reference is independent of namespace and core Secret ownership.

run "fully_customer_managed_secrets_plan_cleanly" {
  command = plan

  variables {
    create_namespace   = false
    n8n_kube_namespace = "existing-n8n"

    existing_n8n_core_secret_name = "existing-core-secrets"
    n8n_license_key               = null
    n8n_license_key_secret_ref = {
      name = "n8n-license"
      key  = "license-key"
    }

    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    n8n_database_password_secret_ref = {
      name = "external-db-credentials"
    }

    create_redis_instance = false
    redis_host            = "10.1.2.3"
    redis_password_secret_ref = {
      name = "external-redis-credentials"
    }

    create_gcs_bucket              = false
    existing_gcs_bucket_name       = "existing-bucket"
    gcs_hmac_service_account_email = "byo-hmac@test-project.iam.gserviceaccount.com"
    gcs_hmac_access_id             = "GOOG1EXAMPLEACCESSID"
    gcs_hmac_secret_name           = "existing-hmac-secret"
  }

  assert {
    condition     = length(kubernetes_namespace.n8n) == 0
    error_message = "No namespace should be created."
  }

  assert {
    condition     = length(kubernetes_secret.n8n) == 0
    error_message = "No core Secret should be created."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_db) == 0
    error_message = "No database Secret should be created."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_redis) == 0
    error_message = "No Redis Secret should be created."
  }

  assert {
    condition     = length(kubernetes_secret.n8n_s3) == 0
    error_message = "No S3/HMAC Secret should be created."
  }
}

# ── Workload Identity binding for an existing, cross-project GKE cluster ─────

run "workload_identity_uses_effective_pool_for_existing_gke" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
    existing_gke_workload_identity_pool    = "other-project.svc.id.goog"
  }

  override_data {
    target = data.google_container_cluster.existing
    values = {
      endpoint        = "10.0.0.2"
      networking_mode = "VPC_NATIVE"
      master_auth = [{
        client_certificate        = ""
        client_certificate_config = []
        client_key                = ""
        cluster_ca_certificate    = "ZmFrZS1jYQ=="
      }]
      workload_identity_config = [{ workload_pool = "other-project.svc.id.goog" }]
    }
  }

  assert {
    condition     = google_service_account_iam_member.n8n_workload_identity.member == "serviceAccount:other-project.svc.id.goog[n8n/n8n]"
    error_message = "The Workload Identity binding must use the existing cluster's cross-project pool."
  }
}
