# Plan-time tests for the worker-pools example using mocked providers.
#
# Exercises the module wiring without contacting Google Cloud.
#
# Run: terraform test
#   (from examples/worker-pools/ - requires terraform >= 1.11)

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}

variables {
  project_id        = "test-project"
  n8n_fqdn          = "n8n.test.example.com"
  n8n_license_key   = "test-license-key-not-real"
  n8n_image_tag     = "2.39.0"
  n8n_chart_version = "1.11.0-preview.workerpools.1"
}

run "defaults_produce_valid_plan" {
  command = plan

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "the module must serve n8n at https://<n8n_fqdn>"
  }
}

run "declares_the_three_pool_topology" {
  command = plan

  assert {
    condition     = length(local.worker_pools) == 3
    error_message = "This example must declare exactly the heavy/secteam/itop topology documented in README.md."
  }

  assert {
    condition     = [for p in local.worker_pools : p.name] == ["heavy", "secteam", "itop"]
    error_message = "Pool names and declaration order must match README.md and outputs.tf's worker_pool_names."
  }

  assert {
    condition     = local.worker_pools[2].min_replicas == 0
    error_message = "itop must demonstrate scale-to-zero (min_replicas = 0)."
  }
}

run "worker_pool_names_output_matches_declared_topology" {
  command = plan

  assert {
    condition     = output.worker_pool_names == ["heavy", "secteam", "itop"]
    error_message = "worker_pool_names output must list every declared pool in declaration order for verify-worker-pools.sh to check against."
  }
}

# The chart-pairing precondition on module.n8n's helm_release.n8n
# (worker-pools.tf) cannot be asserted from here: a parent module's run
# blocks can only address a child module's declared outputs, not its
# internal resources (see AGENTS.md, "Known mock provider limitations"), and
# a resource precondition failure is not itself a checkable object
# expect_failures can reference from the parent. That guard is covered by
# the root module's own test suite (tests/defaults.tftest.hcl,
# "worker_pools_with_numbered_chart_fails_precondition").
