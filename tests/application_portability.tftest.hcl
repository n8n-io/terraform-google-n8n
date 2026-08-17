# Plan-time tests for section 10: custom n8n and task-runner image
# repositories/tags/pull policy/pull Secrets, the n8n chart repository, a
# custom extensions path, execution-data storage mode, the floating-license
# shutdown default, and the n8n_extra_env reserved-name expansion that comes
# with them.
#
# config.extraEnv's actual rendered content lives inside helm_release.n8n.values
# (a JSON-encoded string, unknown at plan time under the mock provider because
# it depends on kubernetes_namespace - see AGENTS.md's known mock-provider
# limitations), so most of this is asserted at the variable-contract layer,
# mirroring the existing OpenTelemetry/log-streaming/External-Secrets test
# pattern. To verify the Helm values end-to-end: run `terraform plan` from
# examples/small/ with these variables set and inspect the helm_release.n8n
# plan output directly.

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

# ── n8n chart repository ──────────────────────────────────────────────────────

run "chart_repository_defaults_to_public_upstream" {
  command = plan

  assert {
    condition     = var.n8n_chart_repository == "oci://ghcr.io/n8n-io/n8n-helm-chart"
    error_message = "n8n_chart_repository should default to the public upstream OCI repository."
  }

  assert {
    condition     = helm_release.n8n.repository == "oci://ghcr.io/n8n-io/n8n-helm-chart"
    error_message = "helm_release.n8n.repository should use n8n_chart_repository."
  }
}

run "chart_repository_accepts_private_mirror" {
  command = plan

  variables {
    n8n_chart_repository = "https://charts.internal.example.com/n8n"
  }

  assert {
    condition     = helm_release.n8n.repository == "https://charts.internal.example.com/n8n"
    error_message = "helm_release.n8n.repository should use a supplied private mirror."
  }
}

run "chart_repository_rejects_invalid_scheme" {
  command = plan

  variables {
    n8n_chart_repository = "ftp://charts.internal.example.com/n8n"
  }

  expect_failures = [var.n8n_chart_repository]
}

# ── n8n application image ─────────────────────────────────────────────────────

run "image_repository_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_repository == null
    error_message = "n8n_image_repository should default to null so the chart's own repository applies."
  }
}

run "image_repository_accepts_bare_reference" {
  command = plan

  variables {
    n8n_image_repository = "us-docker.pkg.dev/test-project/n8n/n8n"
  }

  assert {
    condition     = var.n8n_image_repository == "us-docker.pkg.dev/test-project/n8n/n8n"
    error_message = "n8n_image_repository should accept a bare registry/repository reference."
  }
}

run "image_repository_rejects_scheme" {
  command = plan

  variables {
    n8n_image_repository = "https://us-docker.pkg.dev/test-project/n8n/n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_repository_rejects_embedded_tag" {
  command = plan

  variables {
    n8n_image_repository = "n8nio/n8n:1.2.3"
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_pull_policy_accepts_valid_value" {
  command = plan

  variables {
    n8n_image_pull_policy = "Always"
  }

  assert {
    condition     = var.n8n_image_pull_policy == "Always"
    error_message = "n8n_image_pull_policy should accept Always."
  }
}

run "image_pull_policy_rejects_invalid_value" {
  command = plan

  variables {
    n8n_image_pull_policy = "Sometimes"
  }

  expect_failures = [var.n8n_image_pull_policy]
}

# ── Image pull Secrets and ServiceAccount ownership ───────────────────────────

run "image_pull_secrets_default_to_empty_and_chart_owns_service_account" {
  command = plan

  assert {
    condition     = length(var.n8n_image_pull_secrets) == 0
    error_message = "n8n_image_pull_secrets should default to an empty list."
  }

  assert {
    condition     = length(kubernetes_service_account_v1.n8n) == 0
    error_message = "No module-managed ServiceAccount should be created when n8n_image_pull_secrets is empty; the chart creates its own."
  }
}

run "image_pull_secrets_move_service_account_ownership_to_module" {
  command = plan

  variables {
    n8n_image_repository   = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_pull_secrets = ["ar-pull-creds"]
  }

  assert {
    condition     = length(kubernetes_service_account_v1.n8n) == 1
    error_message = "A module-managed ServiceAccount should be created when n8n_image_pull_secrets is non-empty."
  }

  assert {
    condition     = kubernetes_service_account_v1.n8n[0].metadata[0].name == "n8n-pull"
    error_message = "The module-managed ServiceAccount should use a name distinct from the chart's default (n8n) to avoid a collision on an already-applied stack."
  }
}

run "image_pull_secrets_rejects_invalid_name" {
  command = plan

  variables {
    n8n_image_repository   = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_pull_secrets = ["Invalid_Name"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "image_pull_secrets_rejects_duplicates" {
  command = plan

  variables {
    n8n_image_repository   = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_pull_secrets = ["ar-pull-creds", "ar-pull-creds"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "image_pull_secrets_without_image_repository_triggers_check_warning" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["ar-pull-creds"]
  }

  expect_failures = [check.image_pull_secrets_need_a_custom_image]
}

# ── Task runner image ─────────────────────────────────────────────────────────

run "task_runner_image_tag_and_repository_default_to_null" {
  command = plan

  assert {
    condition     = var.n8n_task_runner_image_tag == null && var.n8n_task_runner_image_repository == null
    error_message = "Task runner image repository/tag should default to null so the chart inherits from the app image's tag."
  }
}

run "task_runner_image_tag_accepts_concrete_version" {
  command = plan

  variables {
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_task_runner_image_tag == "2.27.4"
    error_message = "n8n_task_runner_image_tag should accept a concrete version string."
  }
}

run "task_runner_image_tag_set_without_task_runners_triggers_check_warning" {
  command = plan

  variables {
    n8n_task_runner_image_tag = "2.27.4"
    n8n_task_runners_enabled  = false
  }

  expect_failures = [check.task_runner_image_tag_requires_task_runners]
}

run "custom_image_without_matching_task_runner_tag_triggers_check_warning" {
  command = plan

  variables {
    n8n_image_repository = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_tag        = "2.27.4-mypackages"
  }

  expect_failures = [check.custom_image_tag_requires_task_runner_tag]
}

# ── Custom extensions path ────────────────────────────────────────────────────

run "custom_extensions_path_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_custom_extensions_path == null
    error_message = "n8n_custom_extensions_path should default to null so N8N_CUSTOM_EXTENSIONS is omitted."
  }
}

run "custom_extensions_path_accepts_absolute_path" {
  command = plan

  variables {
    n8n_image_repository       = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_custom_extensions_path = "/opt/n8n-nodes"
  }

  assert {
    condition     = var.n8n_custom_extensions_path == "/opt/n8n-nodes"
    error_message = "n8n_custom_extensions_path should accept an absolute path."
  }
}

run "custom_extensions_path_rejects_relative_path" {
  command = plan

  variables {
    n8n_custom_extensions_path = "opt/n8n-nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_semicolon" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n;nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_trailing_slash" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes/"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_double_slash" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt//n8n-nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_home_node_n8n" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/.n8n/extra"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_without_image_repository_triggers_check_warning" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes"
  }

  expect_failures = [check.custom_extensions_path_requires_a_custom_image]
}

# ── Execution data storage mode ───────────────────────────────────────────────

run "execution_data_storage_mode_defaults_to_database" {
  command = plan

  assert {
    condition     = var.n8n_execution_data_storage_mode == "database"
    error_message = "n8n_execution_data_storage_mode should default to \"database\"."
  }
}

run "execution_data_storage_mode_accepts_s3" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
  }

  assert {
    condition     = var.n8n_execution_data_storage_mode == "s3"
    error_message = "n8n_execution_data_storage_mode should accept \"s3\"."
  }
}

run "execution_data_storage_mode_rejects_filesystem" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}

run "execution_data_storage_mode_s3_with_old_image_tag_triggers_check_warning" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
    n8n_image_tag                   = "2.26.0"
  }

  expect_failures = [check.execution_data_s3_requires_n8n_2_27]
}

run "execution_data_storage_mode_s3_with_new_image_tag_plans_cleanly" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
    n8n_image_tag                   = "2.27.4"
  }

  assert {
    condition     = var.n8n_execution_data_storage_mode == "s3"
    error_message = "execution_data_storage_mode = s3 should plan cleanly with a compatible image tag."
  }
}

# ── Floating-license shutdown default ─────────────────────────────────────────

run "license_detach_floating_on_shutdown_defaults_to_false" {
  command = plan

  assert {
    condition     = var.n8n_license_detach_floating_on_shutdown == false
    error_message = "n8n_license_detach_floating_on_shutdown should default to false to avoid multi-main shutdown/restart loops."
  }
}

run "license_detach_floating_on_shutdown_accepts_true" {
  command = plan

  variables {
    n8n_license_detach_floating_on_shutdown = true
  }

  assert {
    condition     = var.n8n_license_detach_floating_on_shutdown == true
    error_message = "n8n_license_detach_floating_on_shutdown should accept true for single-main deployments that want n8n's upstream behavior."
  }
}

# ── n8n_extra_env reserved-name expansion ─────────────────────────────────────
# Regression guards: every env var this section adds must be rejected by the
# escape hatch, keeping local.n8n_managed_env_names in sync.

run "extra_env_rejects_custom_extensions_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_CUSTOM_EXTENSIONS", value = "/opt/evil" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_license_detach_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_execution_data_storage_mode_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_EXECUTION_DATA_STORAGE_MODE", value = "s3" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_node_extra_ca_certs_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "NODE_EXTRA_CA_CERTS", value = "/tmp/unmanaged-ca.crt" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}
