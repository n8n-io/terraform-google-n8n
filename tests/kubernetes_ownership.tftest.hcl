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

# helm_release.values is unknown at plan time under the mock provider (see
# AGENTS.md's "Known mock provider limitations"); tests/scripts/check-n8n-chart.sh
# renders the real chart and asserts license.activationKey/existingSecret there.
# These plan-time assertions cover the effective locals and the managed
# Secret's own data instead.
run "direct_license_key_creates_managed_secret_no_literal_in_helm_values" {
  command = plan

  assert {
    condition     = length(kubernetes_secret.n8n_license) == 1
    error_message = "A direct n8n_license_key must create a dedicated module-managed license Secret."
  }

  assert {
    condition     = kubernetes_secret.n8n_license[0].data["license-key"] == "test-license-key-not-real"
    error_message = "The managed license Secret must carry the exact supplied key."
  }

  assert {
    condition     = local.effective_license_secret_name == "n8n-license-secret"
    error_message = "The effective license Secret name must point at the managed Secret."
  }

  assert {
    condition     = local.effective_license_secret_key == "license-key"
    error_message = "The managed license Secret's key must be license-key."
  }

  assert {
    condition = (
      local.n8n_license_values.enabled == true &&
      local.n8n_license_values.activationKey == "" &&
      local.n8n_license_values.existingSecret.name == "n8n-license-secret" &&
      local.n8n_license_values.existingSecret.key == "license-key"
    )
    error_message = "On the key path the chart's license values must enable the license and point existingSecret at the effective license Secret, with no literal activationKey."
  }
}

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

  assert {
    condition     = length(kubernetes_secret.n8n_license) == 0
    error_message = "A caller-managed license Secret reference must not create a duplicate managed license Secret."
  }

  assert {
    condition     = local.effective_license_secret_name == "n8n-license"
    error_message = "The caller-supplied license Secret name must be used as-is."
  }

  assert {
    condition     = local.effective_license_secret_key == "activation-key"
    error_message = "The caller-supplied license Secret key must be used as-is."
  }

  assert {
    condition = (
      local.n8n_license_values.existingSecret.name == "n8n-license" &&
      local.n8n_license_values.existingSecret.key == "activation-key"
    )
    error_message = "On the caller-managed key path the chart's license.existingSecret must point at the caller-supplied Secret name and key."
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

run "license_cert_secret_ref_creates_no_managed_secret" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "platform-n8n-license-cert", key = "cert" }
  }

  assert {
    condition     = length(kubernetes_secret.n8n_license) == 0
    error_message = "n8n_license_cert_secret_ref must not create a managed license Secret."
  }

  assert {
    condition     = local.effective_license_secret_name == null && local.effective_license_secret_key == null
    error_message = "The offline-certificate path must resolve effective_license_secret_name/key to null; no license key Secret is referenced."
  }

  assert {
    condition     = !contains(keys(local.n8n_license_values), "existingSecret")
    error_message = "The offline-certificate path must omit license.existingSecret, so the chart's license helper falls back to its empty default and emits no N8N_LICENSE_ACTIVATION_KEY."
  }

  assert {
    condition     = local.n8n_license_values.enabled == true && local.n8n_license_values.activationKey == ""
    error_message = "license.enabled must stay true on the offline-certificate path (the chart gates N8N_MULTI_MAIN_SETUP_ENABLED on it), with no literal activationKey."
  }

  assert {
    condition     = contains(local.n8n_managed_env_names, "N8N_LICENSE_CERT")
    error_message = "N8N_LICENSE_CERT must be reserved against the extra env inputs while n8n_license_cert_secret_ref is set."
  }

  assert {
    condition     = length(local.n8n_license_cert_env) == 1
    error_message = "local.n8n_license_cert_env must carry exactly one entry when n8n_license_cert_secret_ref is set."
  }

  assert {
    condition = (
      local.n8n_license_cert_env[0].name == "N8N_LICENSE_CERT" &&
      local.n8n_license_cert_env[0].valueFrom.secretKeyRef.name == "platform-n8n-license-cert" &&
      local.n8n_license_cert_env[0].valueFrom.secretKeyRef.key == "cert"
    )
    error_message = "local.n8n_license_cert_env's single entry must be N8N_LICENSE_CERT sourced from n8n_license_cert_secret_ref via secretKeyRef."
  }
}

# Not assertable under mocks: that helm_release.n8n's config.extraEnv
# actually includes local.n8n_license_cert_env (n8n.tf), because
# helm_release.values is unknown at plan time (AGENTS.md's "Known mock
# provider limitations"). tests/scripts/check-n8n-chart.sh proves the chart
# renders such an entry on every pod role. To verify the module wiring
# itself, run a real `terraform plan` from an example root with
# n8n_license_cert_secret_ref set and check the rendered values for an
# N8N_LICENSE_CERT entry with a secretKeyRef, or run
# `kubectl -n <namespace> get deploy n8n-main -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="N8N_LICENSE_CERT")]}'`
# after apply.

run "license_cert_secret_ref_key_defaults_to_cert" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "platform-n8n-license-cert" }
  }

  assert {
    condition     = var.n8n_license_cert_secret_ref.key == "cert"
    error_message = "n8n_license_cert_secret_ref.key must default to \"cert\" when omitted."
  }
}

run "rejects_license_key_and_cert_secret_ref_together" {
  command = plan

  variables {
    n8n_license_key             = "test-license-key-not-real"
    n8n_license_cert_secret_ref = { name = "platform-n8n-license-cert" }
  }

  expect_failures = [var.n8n_license_key_secret_ref]
}

run "rejects_license_key_secret_ref_and_cert_secret_ref_together" {
  command = plan

  variables {
    n8n_license_key = null
    n8n_license_key_secret_ref = {
      name = "platform-n8n-license"
    }
    n8n_license_cert_secret_ref = { name = "platform-n8n-license-cert" }
  }

  expect_failures = [var.n8n_license_key_secret_ref]
}

run "rejects_no_license_credential_set" {
  command = plan

  variables {
    n8n_license_key = null
  }

  expect_failures = [var.n8n_license_key_secret_ref]
}

run "rejects_empty_license_cert_secret_ref_name" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "", key = "cert" }
  }

  expect_failures = [var.n8n_license_cert_secret_ref]
}

run "rejects_malformed_license_cert_secret_ref_name" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "Not_A_Valid_K8s_Name!", key = "cert" }
  }

  expect_failures = [var.n8n_license_cert_secret_ref]
}

run "rejects_malformed_license_cert_secret_ref_key" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "platform-n8n-license-cert", key = "not a valid key" }
  }

  expect_failures = [var.n8n_license_cert_secret_ref]
}

run "rejects_null_license_cert_secret_ref_name" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = null, key = "cert" }
  }

  expect_failures = [var.n8n_license_cert_secret_ref]
}

# Each dot-separated part of a DNS-1123 subdomain must start and end with an
# alphanumeric, so an empty part or a part next to a hyphen is invalid.
run "rejects_license_cert_secret_ref_name_with_empty_label" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "n8n..license", key = "cert" }
  }

  expect_failures = [var.n8n_license_cert_secret_ref]
}

run "rejects_license_cert_secret_ref_name_with_hyphen_after_dot" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "n8n.-license", key = "cert" }
  }

  expect_failures = [var.n8n_license_cert_secret_ref]
}

run "accepts_dotted_license_cert_secret_ref_name" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "n8n.license-cert", key = "tls.cert" }
  }

  assert {
    condition     = local.n8n_license_cert_env[0].valueFrom.secretKeyRef.name == "n8n.license-cert" && local.n8n_license_cert_env[0].valueFrom.secretKeyRef.key == "tls.cert"
    error_message = "A valid dotted Secret name and key must pass validation and render as-is."
  }
}

# Kubernetes rejects a Secret data key of "." or one starting with "..".
run "rejects_license_cert_secret_ref_key_dot" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "platform-n8n-license-cert", key = "." }
  }

  expect_failures = [var.n8n_license_cert_secret_ref]
}

run "rejects_license_cert_secret_ref_key_dot_dot" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "platform-n8n-license-cert", key = ".." }
  }

  expect_failures = [var.n8n_license_cert_secret_ref]
}

run "rejects_license_cert_secret_ref_key_with_dot_dot_prefix" {
  command = plan

  variables {
    n8n_license_key             = null
    n8n_license_cert_secret_ref = { name = "platform-n8n-license-cert", key = "..cert" }
  }

  expect_failures = [var.n8n_license_cert_secret_ref]
}

run "existing_core_secret_accepts_license_cert_secret_ref" {
  command = plan

  variables {
    existing_n8n_core_secret_name = "existing-core-secrets"
    n8n_license_key               = null
    n8n_license_cert_secret_ref   = { name = "platform-n8n-license-cert" }
  }

  assert {
    condition     = length(kubernetes_secret.n8n) == 0
    error_message = "An existing core Secret must not create the module-managed core Secret, whichever license source satisfies it."
  }
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

# ── Canonical editor and webhook URLs (section 19) ──────────────────────────
# The rendered config.extraEnv N8N_WEBHOOK_URL/WEBHOOK_URL/N8N_EDITOR_BASE_URL
# entries live inside helm_release.n8n.values (unknown at plan time under the
# mock provider - see AGENTS.md's known mock-provider limitations), so these
# assert directly on local.effective_webhook_url, on
# local.n8n_webhook_url_env (the exact webhook list n8n.tf's extraEnv block
# splices in), and on n8n_fqdn/n8n_webhook_url themselves. End-to-end wiring
# is covered by tests/scripts/check-n8n-chart.sh.

run "webhook_url_defaults_to_canonical_fqdn" {
  command = plan

  assert {
    condition     = local.effective_webhook_url == "https://n8n.test.example.com"
    error_message = "The default effective webhook URL must be https://<n8n_fqdn> when n8n_webhook_url is not set."
  }
}

run "webhook_url_split_from_editor_host" {
  command = plan

  variables {
    n8n_fqdn        = "editor.example.com"
    n8n_webhook_url = "https://hooks.example.com"
  }

  assert {
    condition     = local.effective_webhook_url == "https://hooks.example.com"
    error_message = "An explicit n8n_webhook_url must be used as the effective webhook URL."
  }

  assert {
    condition     = local.n8n_fqdn == "editor.example.com"
    error_message = "The editor base URL host (N8N_EDITOR_BASE_URL) is always derived from n8n_fqdn, independent of n8n_webhook_url."
  }
}

run "webhook_url_rejects_embedded_credentials" {
  command = plan

  variables {
    n8n_webhook_url = "https://user:pass@hooks.example.com"
  }

  expect_failures = [var.n8n_webhook_url]
}

run "webhook_url_rejects_query_string" {
  command = plan

  variables {
    n8n_webhook_url = "https://hooks.example.com/?foo=bar"
  }

  expect_failures = [var.n8n_webhook_url]
}

run "webhook_url_rejects_fragment" {
  command = plan

  variables {
    n8n_webhook_url = "https://hooks.example.com/#section"
  }

  expect_failures = [var.n8n_webhook_url]
}

run "webhook_url_rejects_non_https_scheme" {
  command = plan

  variables {
    n8n_webhook_url = "http://hooks.example.com"
  }

  expect_failures = [var.n8n_webhook_url]
}

run "webhook_url_accepts_path" {
  command = plan

  variables {
    n8n_webhook_url = "https://hooks.example.com/n8n"
  }

  assert {
    condition     = local.effective_webhook_url == "https://hooks.example.com/n8n"
    error_message = "A valid https base URL with a path and no query/fragment/credentials must be accepted."
  }
}

# ── Legacy WEBHOOK_URL ────────────────────────────────────────────────────────
# n8n logs a deprecation warning for WEBHOOK_URL from 2.30.0, the release that
# added N8N_WEBHOOK_URL. Older images build webhook URLs from it, so the module
# drops the legacy name only when the tags prove the image is current and sends
# it whenever they cannot (local.n8n_needs_legacy_webhook_url_env). Ported from
# terraform-aws-n8n#160. List assertions compare a joined string, not the list
# itself, because a list/object `==` between differently typed expressions
# fails silently (see AGENTS.md).

run "legacy_webhook_url_omitted_for_chart_default_image" {
  command = plan

  assert {
    condition     = !local.n8n_needs_legacy_webhook_url_env
    error_message = "A null n8n_image_tag runs the chart's default (2.30.0 or newer), which must not receive the deprecated WEBHOOK_URL."
  }

  assert {
    condition     = join(",", [for e in local.n8n_webhook_url_env : "${e.name}=${e.value}"]) == "N8N_WEBHOOK_URL=https://n8n.test.example.com"
    error_message = "At the defaults, config.extraEnv must carry N8N_WEBHOOK_URL alone."
  }
}

run "legacy_webhook_url_omitted_from_2_30_0" {
  command = plan

  variables {
    n8n_image_tag = "2.30.0"
  }

  assert {
    condition     = !local.n8n_needs_legacy_webhook_url_env
    error_message = "n8n 2.30.0 reads N8N_WEBHOOK_URL and must not receive the deprecated WEBHOOK_URL."
  }
}

run "legacy_webhook_url_emitted_before_2_30_0" {
  command = plan

  variables {
    n8n_image_tag   = "2.29.8"
    n8n_webhook_url = "https://hooks.example.com"
  }

  assert {
    condition     = local.n8n_needs_legacy_webhook_url_env
    error_message = "n8n 2.29.x only reads WEBHOOK_URL, so the module must still emit it."
  }

  assert {
    condition     = join(",", [for e in local.n8n_webhook_url_env : "${e.name}=${e.value}"]) == "N8N_WEBHOOK_URL=https://hooks.example.com,WEBHOOK_URL=https://hooks.example.com"
    error_message = "For a pre-2.30.0 image, config.extraEnv must carry WEBHOOK_URL with the same value as N8N_WEBHOOK_URL."
  }
}

run "legacy_webhook_url_emitted_for_n8n_1_x" {
  command = plan

  # n8n 1.x is unsupported, but a minor above 30 on major 1 must still not
  # read as 2.30.0 or newer: the comparison checks the major first.
  variables {
    n8n_image_tag = "1.123.4"
  }

  assert {
    condition     = local.n8n_needs_legacy_webhook_url_env
    error_message = "n8n 1.x predates N8N_WEBHOOK_URL, so the module must emit WEBHOOK_URL."
  }
}

run "legacy_webhook_url_emitted_for_floating_upstream_tag" {
  command = plan

  variables {
    n8n_image_tag             = "stable"
    n8n_task_runner_image_tag = "2.41.4"
  }

  # The runner-tag fallback is for custom images only, and the chart pulls
  # with IfNotPresent, so a floating tag can run an older cached image.
  assert {
    condition     = local.n8n_needs_legacy_webhook_url_env
    error_message = "A floating upstream tag proves no version, even with a current runner tag, so the module must emit WEBHOOK_URL."
  }
}

run "legacy_webhook_url_uses_runner_tag_for_custom_image_tag" {
  command = plan

  variables {
    n8n_image_repository      = "registry.example.com/n8n"
    n8n_image_tag             = "mypackages"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = local.n8n_needs_legacy_webhook_url_env
    error_message = "A custom tag with no version must fall back to n8n_task_runner_image_tag's version (2.27.4, pre-2.30.0)."
  }
}

# cubic on #13: "2.30.mypackages" carries no full version, so it must not count
# as proof of 2.30.0; the pre-2.30.0 runner tag decides instead.
run "legacy_webhook_url_ignores_tag_without_a_numeric_patch" {
  command = plan

  variables {
    n8n_image_repository      = "registry.example.com/n8n"
    n8n_image_tag             = "2.30.mypackages"
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = local.n8n_needs_legacy_webhook_url_env
    error_message = "A tag without a numeric patch (2.30.mypackages) must not prove n8n 2.30.0; the 2.27.4 runner tag must decide, so WEBHOOK_URL is emitted."
  }
}

run "legacy_webhook_url_uses_current_runner_tag_for_custom_image_tag" {
  command = plan

  variables {
    n8n_image_repository      = "registry.example.com/n8n"
    n8n_image_tag             = "mypackages"
    n8n_task_runner_image_tag = "2.41.4"
  }

  assert {
    condition     = !local.n8n_needs_legacy_webhook_url_env
    error_message = "A custom image whose runner tag is 2.30.0 or newer must not receive the deprecated WEBHOOK_URL."
  }
}

run "legacy_webhook_url_ignores_runner_tag_when_image_tag_is_null" {
  command = plan

  variables {
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = !local.n8n_needs_legacy_webhook_url_env
    error_message = "A null n8n_image_tag runs the chart default, so a pre-2.30.0 runner tag must not emit WEBHOOK_URL."
  }
}

run "legacy_webhook_url_ignores_runner_tag_with_runners_disabled" {
  command = plan

  variables {
    n8n_image_repository      = "registry.example.com/n8n"
    n8n_image_tag             = "mypackages"
    n8n_task_runner_image_tag = "2.41.4"
    n8n_task_runners_enabled  = false
  }

  # Setting a runner tag with runners disabled also raises this warning.
  expect_failures = [check.task_runner_image_tag_requires_task_runners]

  assert {
    condition     = local.n8n_needs_legacy_webhook_url_env
    error_message = "With task runners disabled the runner tag is ignored, so a custom image with no version in its tag must emit WEBHOOK_URL."
  }
}

run "legacy_webhook_url_emitted_for_floating_chart_default" {
  command = plan

  variables {
    n8n_chart_version = "1.11.0"
  }

  assert {
    condition     = local.n8n_needs_legacy_webhook_url_env
    error_message = "Charts 1.4.0 to 1.11.x default to the floating `stable` tag, so a null n8n_image_tag there must emit WEBHOOK_URL."
  }
}

run "legacy_webhook_url_emitted_for_chart_0_x_default" {
  command = plan

  variables {
    n8n_chart_version = "0.12.0"
  }

  assert {
    condition     = local.n8n_needs_legacy_webhook_url_env
    error_message = "A null n8n_image_tag counts as current only at chart 1.12.0 or newer, so a 0.x chart with minor 12 must still emit WEBHOOK_URL."
  }
}

run "legacy_webhook_url_omitted_from_chart_1_12_0_default" {
  command = plan

  variables {
    n8n_chart_version = "1.12.0"
  }

  assert {
    condition     = !local.n8n_needs_legacy_webhook_url_env
    error_message = "Chart 1.12.0 defaults to n8n 2.39.6, so a null n8n_image_tag there must not emit WEBHOOK_URL."
  }
}

run "legacy_webhook_url_emitted_for_custom_chart_repository_default" {
  command = plan

  variables {
    n8n_chart_repository = "oci://registry.example.com/charts"
  }

  assert {
    condition     = local.n8n_needs_legacy_webhook_url_env
    error_message = "A custom chart repository's default appVersion cannot be verified, so a null n8n_image_tag there must emit WEBHOOK_URL."
  }
}
