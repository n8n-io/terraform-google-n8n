# Plan-time tests for section 6: execution-save controls
# (n8n_executions_data_save_on_success / on_error / on_progress /
# manual_executions), wired into local.n8n_executions_data (locals.tf) and
# consumed by helm_release.n8n.values.executions.data (n8n.tf), replacing the
# four literals that used to live directly in that block.
#
# The rendered chart value itself lives inside helm_release.n8n.values (a
# JSON-encoded string, unknown at plan time under the mock provider - see
# AGENTS.md's known mock-provider limitations), so the combined-render
# assertion for task 6.1 is verified at the local-value layer here, mirroring
# the queue_worker_tuning.tftest.hcl pattern.
# tests/scripts/check-n8n-chart.sh separately proves the pinned chart renders
# an executions.data fixture built the same way into the four
# EXECUTIONS_DATA_SAVE_* env vars on the main and worker containers. To
# verify the rendered executions.data map end-to-end: run `terraform plan`
# from examples/small/ with these variables set and inspect the
# helm_release.n8n plan output directly.

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

# ── Defaults ──────────────────────────────────────────────────────────────────

run "execution_save_policy_defaults_preserve_prior_hardcoded_values" {
  command = plan

  assert {
    condition = (
      var.n8n_executions_data_save_on_success == "all" &&
      var.n8n_executions_data_save_on_error == "all" &&
      var.n8n_executions_data_save_on_progress == false &&
      var.n8n_executions_data_save_manual_executions == true
    )
    error_message = "The four execution-save inputs must default to all/all/false/true, matching what n8n.tf's executions.data block used to hardcode."
  }

  assert {
    condition = (
      local.n8n_executions_data.saveOnSuccess == "all" &&
      local.n8n_executions_data.saveOnError == "all" &&
      local.n8n_executions_data.saveOnProgress == false &&
      local.n8n_executions_data.saveManualExecutions == true
    )
    error_message = "local.n8n_executions_data must reflect the default execution-save inputs unchanged."
  }
}

# ── Mixed policy propagates through the shared local ─────────────────────────

run "execution_save_policy_mixed_values_propagate" {
  command = plan

  variables {
    n8n_executions_data_save_on_success        = "none"
    n8n_executions_data_save_on_error          = "all"
    n8n_executions_data_save_on_progress       = true
    n8n_executions_data_save_manual_executions = false
  }

  assert {
    condition = (
      local.n8n_executions_data.saveOnSuccess == "none" &&
      local.n8n_executions_data.saveOnError == "all" &&
      local.n8n_executions_data.saveOnProgress == true &&
      local.n8n_executions_data.saveManualExecutions == false
    )
    error_message = "local.n8n_executions_data must carry a mixed success/error/progress/manual policy through to the chart's executions.data map exactly as configured."
  }
}

# ── n8n_executions_data_save_on_success / on_error validation (all/none) ────

run "executions_data_save_on_success_rejects_invalid_value" {
  command = plan

  variables {
    n8n_executions_data_save_on_success = "some"
  }

  expect_failures = [var.n8n_executions_data_save_on_success]
}

run "executions_data_save_on_error_rejects_invalid_value" {
  command = plan

  variables {
    n8n_executions_data_save_on_error = "some"
  }

  expect_failures = [var.n8n_executions_data_save_on_error]
}

run "executions_data_save_on_success_accepts_none" {
  command = plan

  variables {
    n8n_executions_data_save_on_success = "none"
  }

  assert {
    condition     = var.n8n_executions_data_save_on_success == "none"
    error_message = "n8n_executions_data_save_on_success must accept \"none\"."
  }
}

run "executions_data_save_on_error_accepts_none" {
  command = plan

  variables {
    n8n_executions_data_save_on_error = "none"
  }

  assert {
    condition     = var.n8n_executions_data_save_on_error == "none"
    error_message = "n8n_executions_data_save_on_error must accept \"none\"."
  }
}

# ── n8n_extra_env reserved-name expansion ─────────────────────────────────────
# Regression guards: each EXECUTIONS_DATA_SAVE_* name this section reserves
# must be rejected by the escape hatch, per task 6.2.

run "extra_env_rejects_executions_data_save_on_success_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "EXECUTIONS_DATA_SAVE_ON_SUCCESS", value = "none" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_executions_data_save_on_error_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "EXECUTIONS_DATA_SAVE_ON_ERROR", value = "none" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_executions_data_save_on_progress_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "EXECUTIONS_DATA_SAVE_ON_PROGRESS", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_executions_data_save_manual_executions_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS", value = "false" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}
