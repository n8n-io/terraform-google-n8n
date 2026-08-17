# Plan-time tests for section 9: n8n's External Secrets master switch and
# update interval, and Google Secret Manager access for the n8n Workload
# Identity service account (secret-scoped IAM only, driven by a required,
# wildcard-free allow-list). config.extraEnv's actual rendered content lives
# inside helm_release.n8n.values (a JSON-encoded string, unknown at plan time
# under the mock provider - see AGENTS.md's known mock-provider limitations),
# so External Secrets env-var wiring is asserted at the variable contract
# layer, mirroring the existing OpenTelemetry/log-streaming test pattern.

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

# ── External Secrets defaults ─────────────────────────────────────────────────

run "external_secrets_defaults_enabled" {
  command = plan

  assert {
    condition     = var.n8n_external_secrets_enabled == true
    error_message = "n8n_external_secrets_enabled must default to true, matching n8n's own default (the feature is available unless explicitly disabled)."
  }

  assert {
    condition     = var.n8n_external_secrets_update_interval == null
    error_message = "n8n_external_secrets_update_interval must default to null so n8n's own default (300s) applies."
  }

  assert {
    condition     = local.n8n_disabled_modules == ""
    error_message = "local.n8n_disabled_modules must be empty when External Secrets is enabled (the default)."
  }
}

run "external_secrets_disabled_adds_module_to_disabled_list" {
  command = plan

  variables {
    n8n_external_secrets_enabled = false
  }

  assert {
    condition     = local.n8n_disabled_modules == "external-secrets"
    error_message = "Disabling n8n_external_secrets_enabled must add external-secrets to local.n8n_disabled_modules (rendered into N8N_DISABLED_MODULES)."
  }
}

run "external_secrets_update_interval_rejects_non_positive" {
  command = plan

  variables {
    n8n_external_secrets_update_interval = 0
  }

  expect_failures = [var.n8n_external_secrets_update_interval]
}

run "external_secrets_update_interval_accepts_positive" {
  command = plan

  variables {
    n8n_external_secrets_update_interval = 120
  }

  assert {
    condition     = var.n8n_external_secrets_update_interval == 120
    error_message = "n8n_external_secrets_update_interval must accept a positive number of seconds."
  }
}

# ── External Secrets opposite-path check ──────────────────────────────────────
# Same regression-guard pattern as `check.otel_tuning_requires_master_switch`
# (tests/defaults.tftest.hcl): a `check` block failure is a warning at
# interactive plan/apply but `terraform test` treats it as a failure, so
# `expect_failures` doubles as "this check is supposed to fire here".

run "external_secrets_update_interval_set_with_master_off_triggers_check_warning" {
  command = plan

  variables {
    n8n_external_secrets_enabled         = false
    n8n_external_secrets_update_interval = 120
  }

  expect_failures = [check.external_secrets_update_interval_requires_master_switch]
}

run "external_secrets_update_interval_set_with_master_on_plans_cleanly" {
  command = plan

  variables {
    n8n_external_secrets_enabled         = true
    n8n_external_secrets_update_interval = 120
  }

  assert {
    condition     = helm_release.n8n.namespace == "n8n"
    error_message = "Master switch on with an update interval set must still plan cleanly (no check warning)."
  }
}

# ── Google Secret Manager: disabled by default ────────────────────────────────

run "secret_manager_disabled_by_default_grants_no_iam" {
  command = plan

  assert {
    condition     = var.n8n_secret_manager_enabled == false
    error_message = "n8n_secret_manager_enabled must default to false."
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.n8n) == 0
    error_message = "No Secret Manager IAM should be granted when n8n_secret_manager_enabled = false."
  }
}

# ── Google Secret Manager: valid allow-list grants secret-scoped IAM ─────────

run "secret_manager_enabled_grants_iam_scoped_to_allow_listed_secrets" {
  command = plan

  variables {
    n8n_secret_manager_enabled = true
    n8n_secret_manager_secret_ids = [
      "projects/test-project/secrets/n8n-smtp-password",
      "projects/test-project/secrets/n8n-api-key",
    ]
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.n8n) == 2
    error_message = "One IAM member must be granted per allow-listed secret."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.n8n["projects/test-project/secrets/n8n-smtp-password"].role == "roles/secretmanager.secretAccessor"
    error_message = "The granted role must be roles/secretmanager.secretAccessor (read-only), not a broader role."
  }

  assert {
    condition     = google_secret_manager_secret_iam_member.n8n["projects/test-project/secrets/n8n-smtp-password"].secret_id == "projects/test-project/secrets/n8n-smtp-password"
    error_message = "IAM must be scoped to the exact allow-listed secret resource ID, not project-wide."
  }
}

# ── Google Secret Manager: existing (Workload Identity) service account ──────
# The IAM member always targets google_service_account.n8n regardless of
# whether the module or an existing GKE cluster owns the surrounding
# Kubernetes/Workload Identity wiring; the n8n Google service account itself
# is always module-managed. member (`serviceAccount:${google_service_account.n8n.email}`)
# is unknown at plan time under the mock google provider (the account_id is
# plan-known but email is a computed attribute), so this is asserted at the
# resource-count/role level above rather than by inspecting the rendered
# member string; see AGENTS.md's known mock-provider limitations.

# ── Google Secret Manager: unsafe or empty allow-lists fail validation ───────

run "secret_manager_enabled_with_empty_list_fails_validation" {
  command = plan

  variables {
    n8n_secret_manager_enabled    = true
    n8n_secret_manager_secret_ids = []
  }

  expect_failures = [var.n8n_secret_manager_enabled]
}

run "secret_manager_wildcard_secret_id_fails_validation" {
  command = plan

  variables {
    n8n_secret_manager_enabled    = true
    n8n_secret_manager_secret_ids = ["projects/test-project/secrets/*"]
  }

  expect_failures = [var.n8n_secret_manager_secret_ids]
}

run "secret_manager_malformed_secret_id_fails_validation" {
  command = plan

  variables {
    n8n_secret_manager_enabled    = true
    n8n_secret_manager_secret_ids = ["n8n-smtp-password"]
  }

  expect_failures = [var.n8n_secret_manager_secret_ids]
}

run "secret_manager_secret_id_with_version_suffix_fails_validation" {
  command = plan

  variables {
    n8n_secret_manager_enabled    = true
    n8n_secret_manager_secret_ids = ["projects/test-project/secrets/n8n-smtp-password/versions/latest"]
  }

  expect_failures = [var.n8n_secret_manager_secret_ids]
}

# ── Secret Manager access is independent of the External Secrets switch ─────
# Enabling Secret Manager IAM while n8n's own External Secrets feature is
# disabled is a valid (if unusual) combination: the IAM grant is inert until
# an operator both re-enables the feature and configures the vault provider.

run "secret_manager_enabled_with_external_secrets_disabled_plans_cleanly" {
  command = plan

  variables {
    n8n_external_secrets_enabled  = false
    n8n_secret_manager_enabled    = true
    n8n_secret_manager_secret_ids = ["projects/test-project/secrets/n8n-smtp-password"]
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.n8n) == 1
    error_message = "Secret Manager IAM must still be granted even when the n8n External Secrets feature switch is off."
  }
}
