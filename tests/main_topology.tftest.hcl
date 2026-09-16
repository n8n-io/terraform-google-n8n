# Plan-time tests for section 3 (main-topology capability): deriving
# single-main vs multi-main from the selected main count, on both scaler
# ownership paths (module-owned HPA, caller-fixed replicas), and the shared
# effective locals that n8n.tf's Helm values and capacity.tf's estimate both
# consume.
#
# helm_release.n8n's values are unknown at plan time (see defaults.tftest.hcl
# and AGENTS.md's "Known mock provider limitations"), so these assertions
# target the Terraform locals the release reads from
# (local.n8n_single_main / n8n_main_strategy / n8n_main_pdb_min_available /
# n8n_effective_main_hpa_max_replicas), which are pure functions of the input
# variables below and fully known at plan time. Chart-rendering proof that the
# chart actually turns these fragments into Recreate/PDB/multiMain behavior
# lives in tests/scripts/check-n8n-chart.sh (task 3.1's chart-rendering
# verification).

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

# ── Managed HPA ownership path ───────────────────────────────────────────────

run "managed_hpa_min_one_selects_single_main" {
  command = plan

  variables {
    n8n_main_hpa_enabled      = true
    n8n_main_hpa_min_replicas = 1
    n8n_main_hpa_max_replicas = 5
  }

  assert {
    condition     = local.n8n_single_main && !local.n8n_main_leader_election_enabled && length(local.n8n_main_election_staging_env) == 0
    error_message = "n8n_main_hpa_min_replicas=1 must select single-main with election disabled by default."
  }

  assert {
    condition     = local.n8n_effective_main_hpa_max_replicas == 1
    error_message = "A module-owned main HPA must clamp its maximum to 1 for single-main, even though n8n_main_hpa_max_replicas=5 was configured (a high, unused single-main maximum)."
  }

  assert {
    condition     = try(local.n8n_main_strategy.type, null) == "Recreate" && length(keys(local.n8n_main_strategy)) == 1
    error_message = "Single-main must render a Recreate main strategy."
  }

  assert {
    condition     = local.n8n_main_pdb_min_available == 0
    error_message = "Single-main's PDB must permit evicting its sole replica (minAvailable=0)."
  }
}

run "managed_hpa_min_two_selects_multi_main" {
  command = plan

  variables {
    n8n_main_hpa_enabled      = true
    n8n_main_hpa_min_replicas = 2
    n8n_main_hpa_max_replicas = 20
  }

  assert {
    condition     = local.n8n_single_main == false
    error_message = "n8n_main_hpa_min_replicas=2 must select multi-main topology."
  }

  assert {
    condition     = local.n8n_effective_main_hpa_max_replicas == 20
    error_message = "Multi-main must use the caller's configured HPA maximum unclamped."
  }

  assert {
    condition     = length(keys(local.n8n_main_strategy)) == 0
    error_message = "Multi-main must leave the main rollout strategy at the chart default ({})."
  }

  assert {
    condition     = local.n8n_main_pdb_min_available == 1
    error_message = "Multi-main must retain the existing PDB floor of minAvailable=1."
  }
}

run "managed_hpa_min_three_remains_multi_main" {
  command = plan

  variables {
    n8n_main_hpa_enabled      = true
    n8n_main_hpa_min_replicas = 3
    n8n_main_hpa_max_replicas = 10
  }

  assert {
    condition     = local.n8n_single_main == false
    error_message = "n8n_main_hpa_min_replicas=3 must select multi-main topology."
  }

  assert {
    condition     = local.n8n_effective_main_hpa_max_replicas == 10
    error_message = "Multi-main at 3 replicas must not clamp the configured HPA maximum."
  }
}

# ── Caller-owned (fixed replica) ownership path ──────────────────────────────

run "fixed_replicas_one_selects_single_main_without_hpa" {
  command = plan

  variables {
    n8n_main_hpa_enabled    = false
    n8n_main_fixed_replicas = 1
  }

  assert {
    condition     = local.n8n_single_main == true
    error_message = "n8n_main_fixed_replicas=1 with the HPA disabled must select single-main topology."
  }

  assert {
    condition     = try(local.n8n_main_strategy.type, null) == "Recreate" && length(keys(local.n8n_main_strategy)) == 1
    error_message = "Single-main via a caller-fixed replica count must still render a Recreate main strategy."
  }

  assert {
    condition     = local.n8n_main_pdb_min_available == 0
    error_message = "Single-main via a caller-fixed replica count must still set minAvailable=0."
  }
}

run "fixed_replicas_two_selects_multi_main_without_hpa" {
  command = plan

  variables {
    n8n_main_hpa_enabled    = false
    n8n_main_fixed_replicas = 2
  }

  assert {
    condition     = local.n8n_single_main == false
    error_message = "n8n_main_fixed_replicas=2 with the HPA disabled must select multi-main topology."
  }

  assert {
    condition     = length(keys(local.n8n_main_strategy)) == 0
    error_message = "Multi-main via a caller-fixed replica count must leave the main strategy at the chart default."
  }

  assert {
    condition     = local.n8n_main_pdb_min_available == 1
    error_message = "Multi-main via a caller-fixed replica count must retain minAvailable=1."
  }
}

# ── Default remains multi-main ───────────────────────────────────────────────

run "defaults_remain_multi_main" {
  command = plan

  assert {
    condition     = var.n8n_main_leader_election_enabled == null && local.n8n_main_leader_election_enabled && !local.n8n_single_main && length(local.n8n_main_election_staging_env) == 0
    error_message = "Unmodified defaults must retain inferred multi-main election at two replicas."
  }
}

# These are independent plans, not sequential upgrades. Real ordering and
# schedule duplication require docs/manual-verification-checklist.md item 2.
run "stage_election_with_managed_hpa" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas        = 1
    n8n_main_leader_election_enabled = true
  }

  assert {
    condition     = local.n8n_main_leader_election_enabled && local.n8n_effective_main_replica_count == 1 && length(local.n8n_main_election_staging_env) == 1
    error_message = "Stage one must enable election without raising the selected count (ignoring fixed replicas while HPA is enabled)."
  }

  assert {
    condition     = try(local.n8n_main_election_staging_env[0].name, null) == "N8N_MULTI_MAIN_SETUP_ENABLED" && try(local.n8n_main_election_staging_env[0].value, null) == "true"
    error_message = "Staging must emit a literal runtime election flag while chart multiMain remains disabled at one replica."
  }

  assert {
    condition     = local.n8n_effective_main_hpa_max_replicas == 1 && local.capacity_main_max_replicas == 1
    error_message = "Election staging must preserve the managed HPA and capacity ceilings of one despite the configured maximum of 20."
  }

  assert {
    condition     = try(local.n8n_main_strategy.type, null) == "Recreate" && length(keys(local.n8n_main_strategy)) == 1 && local.n8n_main_pdb_min_available == 0
    error_message = "Election staging must retain Recreate and PDB minimum 0."
  }
}

run "stage_election_with_fixed_replicas" {
  command = plan

  variables {
    n8n_main_hpa_enabled             = false
    n8n_main_fixed_replicas          = 1
    n8n_main_leader_election_enabled = true
  }

  assert {
    condition     = local.n8n_main_leader_election_enabled && local.n8n_effective_main_replica_count == 1 && local.capacity_main_max_replicas == 1 && length(local.n8n_main_election_staging_env) == 1
    error_message = "Fixed staging must enable election at one replica, ignoring the HPA minimum of two."
  }

  assert {
    condition     = try(local.n8n_main_strategy.type, null) == "Recreate" && length(keys(local.n8n_main_strategy)) == 1 && local.n8n_main_pdb_min_available == 0
    error_message = "Fixed staging must retain Recreate and PDB minimum 0."
  }
}

run "stage_two_retains_explicit_election" {
  command = plan

  variables {
    n8n_main_leader_election_enabled = true
  }

  assert {
    condition     = local.n8n_main_leader_election_enabled && local.n8n_effective_main_replica_count == 2 && local.n8n_effective_main_hpa_max_replicas == 20 && length(local.n8n_main_election_staging_env) == 0
    error_message = "Stage two must keep election enabled while restoring the default HPA limits."
  }

  assert {
    condition     = length(keys(local.n8n_main_strategy)) == 0 && local.n8n_main_pdb_min_available == 1
    error_message = "Stage two must restore the chart strategy and PDB minimum 1."
  }
}

run "explicit_election_disabled_at_one" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas        = 1
    n8n_main_leader_election_enabled = false
  }

  assert {
    condition     = !local.n8n_main_leader_election_enabled && local.n8n_effective_main_hpa_max_replicas == 1 && length(local.n8n_main_election_staging_env) == 0
    error_message = "Explicit false must remain supported at one replica with a clamped HPA."
  }
}

run "staging_cannot_be_overridden_by_extra_env" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas        = 1
    n8n_main_leader_election_enabled = true
    n8n_extra_env = [{
      name  = "N8N_MULTI_MAIN_SETUP_ENABLED"
      value = "false"
    }]
  }

  expect_failures = [var.n8n_extra_env]
}

run "reject_election_disabled_above_one_with_hpa" {
  command = plan

  variables {
    n8n_main_fixed_replicas          = 1
    n8n_main_leader_election_enabled = false
  }

  expect_failures = [var.n8n_main_leader_election_enabled]
}

run "reject_election_disabled_above_one_with_fixed_replicas" {
  command = plan

  variables {
    n8n_main_hpa_enabled             = false
    n8n_main_hpa_min_replicas        = 1
    n8n_main_leader_election_enabled = false
  }

  expect_failures = [var.n8n_main_leader_election_enabled]
}

# ── capacity.tf consumes the same effective, clamped ceiling ────────────────

run "capacity_uses_effective_single_main_ceiling" {
  command = plan

  variables {
    n8n_main_hpa_enabled      = true
    n8n_main_hpa_min_replicas = 1
    n8n_main_hpa_max_replicas = 20
  }

  assert {
    condition     = local.capacity_main_max_replicas == 1
    error_message = "capacity.tf must use the effective, single-main-clamped main ceiling (1), not the raw configured n8n_main_hpa_max_replicas (20)."
  }
}

run "capacity_uses_unclamped_multi_main_ceiling" {
  command = plan

  variables {
    n8n_main_hpa_enabled      = true
    n8n_main_hpa_min_replicas = 2
    n8n_main_hpa_max_replicas = 20
  }

  assert {
    condition     = local.capacity_main_max_replicas == 20
    error_message = "capacity.tf must use the unclamped configured main HPA maximum for multi-main."
  }
}

run "capacity_uses_fixed_replicas_when_hpa_disabled" {
  command = plan

  variables {
    n8n_main_hpa_enabled    = false
    n8n_main_fixed_replicas = 4
  }

  assert {
    condition     = local.capacity_main_max_replicas == 4
    error_message = "capacity.tf must use n8n_main_fixed_replicas as the main ceiling when the caller owns main scaling."
  }
}
