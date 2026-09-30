# Plan-time tests for section 5: queue lease/stall tuning
# (n8n_queue_worker_lock_duration / n8n_queue_worker_lock_renew_time /
# n8n_queue_worker_stalled_interval) and the graceful shutdown timeout
# (n8n_graceful_shutdown_timeout, plus its grace-period validation and the
# null-default graceful_shutdown_fits_grace_period check), wired into one
# nested redis.worker chart map (local.n8n_queue_worker_chart_overrides in locals.tf, consumed by
# helm_release.n8n.values in n8n.tf).
#
# The rendered chart value itself lives inside helm_release.n8n.values (a
# JSON-encoded string, unknown at plan time under the mock provider - see
# AGENTS.md's known mock-provider limitations), so the combined-render
# assertion in task 5.1 is verified at the local-value layer here, mirroring
# the db_health_tuning.tftest.hcl pattern. tests/scripts/check-n8n-chart.sh
# separately proves the pinned chart accepts a redis.worker fixture built the
# same way. To verify the rendered redis.worker map end-to-end: run
# `terraform plan` from examples/small/ with these variables set and inspect
# the helm_release.n8n plan output directly.

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

run "queue_worker_tuning_defaults_to_null" {
  command = plan

  assert {
    condition = (
      var.n8n_queue_worker_lock_duration == null &&
      var.n8n_queue_worker_lock_renew_time == null &&
      var.n8n_queue_worker_stalled_interval == null &&
      var.n8n_graceful_shutdown_timeout == null
    )
    error_message = "All four queue lock/stall/timeout tuning variables must default to null so the chart's own redis.worker defaults (60000/10000/30000/30) apply."
  }

  assert {
    condition     = length(local.n8n_queue_worker_chart_overrides) == 0
    error_message = "With all four tuning variables null, the nested redis.worker override map must be empty so no chart default is touched."
  }
}

# ── Combined render retains all four siblings together ──────────────────────

run "queue_worker_tuning_combined_values_retain_all_four_siblings" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration    = 90000
    n8n_queue_worker_lock_renew_time  = 15000
    n8n_queue_worker_stalled_interval = 45000
    n8n_graceful_shutdown_timeout     = 45
  }

  assert {
    condition = (
      local.n8n_queue_worker_chart_overrides.lockDuration == 90000 &&
      local.n8n_queue_worker_chart_overrides.lockRenewTime == 15000 &&
      local.n8n_queue_worker_chart_overrides.stalledInterval == 45000 &&
      local.n8n_queue_worker_chart_overrides.timeout == 45
    )
    error_message = "Setting all four queue lock/stall/timeout tuning values must retain all four together in the nested redis.worker override map, with no duplicate or competing environment entry (these are chart values, not config.extraEnv)."
  }
}

# ── Single value set does not discard the others' chart defaults ────────────

run "queue_worker_tuning_single_value_omits_the_others" {
  command = plan

  variables {
    n8n_queue_worker_stalled_interval = 20000
  }

  assert {
    condition = (
      !contains(keys(local.n8n_queue_worker_chart_overrides), "lockDuration") &&
      !contains(keys(local.n8n_queue_worker_chart_overrides), "lockRenewTime") &&
      local.n8n_queue_worker_chart_overrides.stalledInterval == 20000
    )
    error_message = "Setting only n8n_queue_worker_stalled_interval must not add lockDuration/lockRenewTime keys, leaving the chart's own defaults for those two untouched."
  }
}

# ── n8n_queue_worker_lock_duration validation ────────────────────────────────

run "lock_duration_rejects_fractional" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration = 60000.5
  }

  expect_failures = [var.n8n_queue_worker_lock_duration]
}

run "lock_duration_rejects_below_1000" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration = 999
  }

  expect_failures = [var.n8n_queue_worker_lock_duration]
}

run "lock_duration_at_its_own_minimum_still_needs_a_shorter_renewal" {
  command = plan

  # The bare minimum duration (1000ms) equals the minimum allowed renewal
  # (1000ms), so no renewal value can be strictly shorter than it; this
  # documents that boundary rather than accepting the duration in isolation.
  variables {
    n8n_queue_worker_lock_duration   = 1000
    n8n_queue_worker_lock_renew_time = 1000
  }

  expect_failures = [var.n8n_queue_worker_lock_renew_time]
}

run "lock_duration_accepts_smallest_viable_combination" {
  command = plan

  # The smallest duration that admits any valid renewal: one millisecond above
  # the shared 1000ms floor, paired with a renewal at that floor.
  variables {
    n8n_queue_worker_lock_duration   = 1001
    n8n_queue_worker_lock_renew_time = 1000
  }

  assert {
    condition = (
      var.n8n_queue_worker_lock_duration == 1001 &&
      var.n8n_queue_worker_lock_renew_time == 1000
    )
    error_message = "n8n_queue_worker_lock_duration must accept a value one millisecond above the shared 1000ms floor when paired with a renewal at that floor."
  }
}

# ── Effective-default cross-validation (renewal strictly less than duration) ─

run "short_duration_with_omitted_renewal_fails" {
  command = plan

  # Duration below the chart's own default renewal (10000) is invalid because
  # the effective renewal (the chart default, since renewal is omitted) would
  # equal or exceed the effective duration.
  variables {
    n8n_queue_worker_lock_duration = 5000
  }

  expect_failures = [var.n8n_queue_worker_lock_renew_time]
}

run "equal_renewal_and_duration_fails" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration   = 10000
    n8n_queue_worker_lock_renew_time = 10000
  }

  expect_failures = [var.n8n_queue_worker_lock_renew_time]
}

run "renewal_not_less_than_duration_fails" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration   = 10000
    n8n_queue_worker_lock_renew_time = 20000
  }

  expect_failures = [var.n8n_queue_worker_lock_renew_time]
}

run "renewal_less_than_duration_passes" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration   = 90000
    n8n_queue_worker_lock_renew_time = 15000
  }

  assert {
    condition = (
      var.n8n_queue_worker_lock_duration == 90000 &&
      var.n8n_queue_worker_lock_renew_time == 15000
    )
    error_message = "A renewal strictly less than duration must pass validation."
  }
}

run "renewal_omitted_with_default_duration_passes" {
  command = plan

  # Duration omitted (falls back to the chart default of 60000) and renewal
  # explicit at a value still strictly less than that default.
  variables {
    n8n_queue_worker_lock_renew_time = 15000
  }

  assert {
    condition     = var.n8n_queue_worker_lock_renew_time == 15000
    error_message = "An explicit renewal strictly less than the chart's default duration (60000) must pass validation."
  }
}

run "lock_renew_time_rejects_fractional" {
  command = plan

  variables {
    n8n_queue_worker_lock_renew_time = 5000.5
  }

  expect_failures = [var.n8n_queue_worker_lock_renew_time]
}

run "lock_renew_time_rejects_below_1000" {
  command = plan

  variables {
    n8n_queue_worker_lock_renew_time = 999
  }

  expect_failures = [var.n8n_queue_worker_lock_renew_time]
}

# ── n8n_queue_worker_stalled_interval validation ─────────────────────────────

run "stalled_interval_rejects_zero" {
  command = plan

  variables {
    n8n_queue_worker_stalled_interval = 0
  }

  expect_failures = [var.n8n_queue_worker_stalled_interval]
}

run "stalled_interval_rejects_fractional" {
  command = plan

  variables {
    n8n_queue_worker_stalled_interval = 30000.25
  }

  expect_failures = [var.n8n_queue_worker_stalled_interval]
}

run "stalled_interval_rejects_below_1000" {
  command = plan

  variables {
    n8n_queue_worker_stalled_interval = 500
  }

  expect_failures = [var.n8n_queue_worker_stalled_interval]
}

run "stalled_interval_accepts_supported_value" {
  command = plan

  variables {
    n8n_queue_worker_stalled_interval = 45000
  }

  assert {
    condition     = var.n8n_queue_worker_stalled_interval == 45000
    error_message = "n8n_queue_worker_stalled_interval must accept a supported whole-millisecond value at or above 1000."
  }
}

# ── n8n_graceful_shutdown_timeout validation ─────────────────────────────────

run "graceful_shutdown_timeout_alone_emits_only_its_key" {
  command = plan

  variables {
    n8n_graceful_shutdown_timeout = 45
  }

  assert {
    condition = (
      !contains(keys(local.n8n_queue_worker_chart_overrides), "lockDuration") &&
      !contains(keys(local.n8n_queue_worker_chart_overrides), "lockRenewTime") &&
      !contains(keys(local.n8n_queue_worker_chart_overrides), "stalledInterval") &&
      local.n8n_queue_worker_chart_overrides.timeout == 45
    )
    error_message = "Setting only n8n_graceful_shutdown_timeout must not add lockDuration/lockRenewTime/stalledInterval keys, leaving the chart's own defaults for those three untouched."
  }
}

run "graceful_shutdown_timeout_rejects_below_1" {
  command = plan

  variables {
    n8n_graceful_shutdown_timeout = 0
  }

  expect_failures = [var.n8n_graceful_shutdown_timeout]
}

run "graceful_shutdown_timeout_rejects_fractional_value" {
  command = plan

  variables {
    n8n_graceful_shutdown_timeout = 45.5
  }

  expect_failures = [var.n8n_graceful_shutdown_timeout]
}

# The pod-level ceiling: n8n_graceful_shutdown_timeout (or its 30s default)
# plus n8n_prestop_sleep must fit under n8n_termination_grace_period, or
# Kubernetes SIGKILLs the pod before n8n's own shutdown window ends.
run "graceful_shutdown_timeout_rejects_when_it_plus_prestop_sleep_exceeds_grace_period" {
  command = plan

  # Defaults: n8n_prestop_sleep = 10, n8n_termination_grace_period = 60.
  # 55 + 10 = 65, over the 60s ceiling.
  variables {
    n8n_graceful_shutdown_timeout = 55
  }

  expect_failures = [var.n8n_graceful_shutdown_timeout]
}

run "graceful_shutdown_timeout_rejects_when_it_plus_prestop_sleep_equals_grace_period" {
  command = plan

  # 50 + the default 10s prestop sleep exactly equals the default 60s grace
  # period. The check requires a strict gap (<), not just meeting the
  # ceiling: Kubernetes starts the terminationGracePeriodSeconds countdown
  # when it invokes preStop, not after preStop finishes, so a sum equal to
  # the ceiling leaves n8n's own shutdown handler no margin before SIGKILL.
  variables {
    n8n_graceful_shutdown_timeout = 50
  }

  expect_failures = [var.n8n_graceful_shutdown_timeout]
}

run "graceful_shutdown_timeout_accepts_when_it_plus_prestop_sleep_is_strictly_below_grace_period" {
  command = plan

  # 49 + the default 10s prestop sleep leaves a 1s margin under the default
  # 60s grace period.
  variables {
    n8n_graceful_shutdown_timeout = 49
  }

  assert {
    condition     = local.n8n_queue_worker_chart_overrides.timeout == 49
    error_message = "n8n_graceful_shutdown_timeout should accept, and local.n8n_queue_worker_chart_overrides should carry, a value whose sum with n8n_prestop_sleep is strictly below n8n_termination_grace_period."
  }
}

run "graceful_shutdown_timeout_follows_a_raised_grace_period" {
  command = plan

  # 100 + 10 = 110 < 120. Would fail against the default 60s ceiling, so this
  # catches a ceiling accidentally hardcoded instead of read from
  # n8n_termination_grace_period.
  variables {
    n8n_termination_grace_period  = 120
    n8n_graceful_shutdown_timeout = 100
  }

  assert {
    condition     = local.n8n_queue_worker_chart_overrides.timeout == 100 && length(keys(local.n8n_queue_worker_chart_overrides)) == 1
    error_message = "An n8n_graceful_shutdown_timeout that fits under a raised n8n_termination_grace_period must plan cleanly and reach local.n8n_queue_worker_chart_overrides."
  }
}

# ── Null default: warning, not error (check.graceful_shutdown_fits_grace_period) ─
# With the input left null the chart still renders its 30s default, which must
# fit under the grace period the same way. That was never checked before this
# input existed, so it is a check (warning) rather than a validation error:
# configurations that planned before keep planning.

run "graceful_shutdown_timeout_null_default_warns_when_it_does_not_fit" {
  command = plan

  # 30 + 31 = 61, over the default 60s grace period. Proves the check
  # accounts for the chart's real default rather than treating null as "no
  # timeout", and that it reports through the check rather than failing the
  # variable's validation.
  variables {
    n8n_prestop_sleep = 31
  }

  expect_failures = [check.graceful_shutdown_fits_grace_period]
}

run "graceful_shutdown_timeout_null_default_warns_at_the_exact_ceiling" {
  command = plan

  # 30 + 30 = 60 equals the default grace period. Before this input existed
  # this planned cleanly, so it must stay a warning, not an error.
  variables {
    n8n_prestop_sleep = 30
  }

  expect_failures = [check.graceful_shutdown_fits_grace_period]
}

run "graceful_shutdown_timeout_null_default_is_silent_when_it_fits" {
  command = plan

  # Module defaults: 30 + 10 < 60. No expect_failures, so the run fails if
  # either the check or the validation fires.
  assert {
    condition     = local.n8n_graceful_shutdown_default_applies && local.n8n_chart_default_graceful_shutdown_timeout == 30
    error_message = "With module defaults, the null-default check must apply and compare against the chart's 30s default."
  }
}

run "graceful_shutdown_timeout_null_default_follows_a_raised_grace_period" {
  command = plan

  # 30 + 60 = 90 < 120. Would warn against the default 60s ceiling, so no
  # expect_failures here proves the check reads the raised grace period.
  variables {
    n8n_termination_grace_period = 120
    n8n_prestop_sleep            = 60
  }

  assert {
    condition     = local.n8n_graceful_shutdown_default_applies
    error_message = "With n8n_graceful_shutdown_timeout unset on the upstream chart, the null-default check must apply."
  }
}

run "graceful_shutdown_timeout_explicit_value_does_not_trigger_the_null_default_check" {
  command = plan

  # prestop 31 would make the chart default warn, but an explicit 20 fits
  # (20 + 31 = 51 < 60), so neither the validation nor the check fires.
  variables {
    n8n_prestop_sleep             = 31
    n8n_graceful_shutdown_timeout = 20
  }

  assert {
    condition     = !local.n8n_graceful_shutdown_default_applies && local.n8n_queue_worker_chart_overrides.timeout == 20
    error_message = "An explicit n8n_graceful_shutdown_timeout that fits must plan cleanly and reach local.n8n_queue_worker_chart_overrides, even when the chart default would not fit."
  }
}

run "graceful_shutdown_timeout_null_default_check_skips_a_custom_chart_repository" {
  command = plan

  # Would warn on the upstream chart (30 + 31 = 61 > 60), but a custom
  # repository's default is unverifiable, so the check must stay quiet. No
  # expect_failures, so the run fails if the check fires.
  variables {
    n8n_chart_repository = "oci://registry.example.com/charts"
    n8n_prestop_sleep    = 31
  }

  assert {
    condition     = !local.n8n_graceful_shutdown_default_applies
    error_message = "local.n8n_graceful_shutdown_default_applies must be false for a custom n8n_chart_repository, so the null-default check does not compare against an unverified default."
  }
}

run "graceful_shutdown_timeout_null_default_warns_on_an_older_upstream_chart_pin" {
  command = plan

  # Every published upstream chart (1.0.0 through 1.14.0) defaults
  # redis.worker.timeout to 30, so the check is not gated on the chart
  # version: 30 + 31 = 61 must still warn on an older upstream pin.
  variables {
    n8n_chart_version = "1.12.0"
    n8n_prestop_sleep = 31
  }

  expect_failures = [check.graceful_shutdown_fits_grace_period]
}

run "graceful_shutdown_timeout_explicit_value_is_validated_on_a_custom_chart_repository" {
  command = plan

  # The explicit-value validation does not depend on the chart's default, so
  # it still applies to a custom repository: 50 + 10 = 60, not below 60.
  variables {
    n8n_chart_repository          = "oci://registry.example.com/charts"
    n8n_graceful_shutdown_timeout = 50
  }

  expect_failures = [var.n8n_graceful_shutdown_timeout]
}

# ── Regression guard: N8N_GRACEFUL_SHUTDOWN_TIMEOUT is reserved ──────────────
# terraform-aws-n8n issue #147, fixed upstream by terraform-aws-n8n#148.
# Chart 1.13.0 renders this ConfigMap key unconditionally on every n8n
# container from redis.worker.timeout, and config.extraEnv is appended after
# it, so a caller duplicate must be rejected at plan time rather than
# silently overriding the chart's real value at apply.

run "extra_env_rejects_graceful_shutdown_timeout_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_GRACEFUL_SHUTDOWN_TIMEOUT", value = "120" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "worker_extra_env_rejects_graceful_shutdown_timeout_name" {
  command = plan

  variables {
    n8n_worker_extra_env = [
      { name = "N8N_GRACEFUL_SHUTDOWN_TIMEOUT", value = "120" },
    ]
  }

  expect_failures = [var.n8n_worker_extra_env]
}

# Same guard on the per-pool input. The pool validation (variables.tf) reads
# the same local.n8n_managed_env_names, so this pins that it keeps doing so.
run "worker_pools_reject_extra_env_setting_graceful_shutdown_timeout" {
  command = plan

  variables {
    n8n_worker_pools = [
      {
        name = "heavy"
        extra_env = [
          { name = "N8N_GRACEFUL_SHUTDOWN_TIMEOUT", value = "120" },
        ]
      },
    ]
  }

  expect_failures = [var.n8n_worker_pools]
}
