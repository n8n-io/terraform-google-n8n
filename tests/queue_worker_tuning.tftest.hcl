# Plan-time tests for section 5: queue lease/stall tuning
# (n8n_queue_worker_lock_duration / n8n_queue_worker_lock_renew_time /
# n8n_queue_worker_stalled_interval), wired into one nested redis.worker chart
# map (local.n8n_queue_worker_chart_overrides in locals.tf, consumed by
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
      var.n8n_queue_worker_stalled_interval == null
    )
    error_message = "All three queue lock/stall tuning variables must default to null so the chart's own redis.worker defaults (60000/10000/30000) apply."
  }

  assert {
    condition     = length(local.n8n_queue_worker_chart_overrides) == 0
    error_message = "With all three tuning variables null, the nested redis.worker override map must be empty so no chart default is touched."
  }
}

# ── Combined render retains all three siblings together ─────────────────────

run "queue_worker_tuning_combined_values_retain_all_three_siblings" {
  command = plan

  variables {
    n8n_queue_worker_lock_duration    = 90000
    n8n_queue_worker_lock_renew_time  = 15000
    n8n_queue_worker_stalled_interval = 45000
  }

  assert {
    condition = (
      local.n8n_queue_worker_chart_overrides.lockDuration == 90000 &&
      local.n8n_queue_worker_chart_overrides.lockRenewTime == 15000 &&
      local.n8n_queue_worker_chart_overrides.stalledInterval == 45000
    )
    error_message = "Setting all three queue lock/stall tuning values must retain all three together in the nested redis.worker override map, with no duplicate or competing environment entry (these are chart values, not config.extraEnv)."
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
