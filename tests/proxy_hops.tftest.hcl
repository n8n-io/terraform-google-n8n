# Plan-time tests for n8n_proxy_hops (inbound reverse-proxy trust).
#
# helm_release.n8n.values is unknown at plan time under the mock provider
# (see AGENTS.md), so the rendered entry is asserted against
# local.n8n_proxy_hops_env, which n8n.tf appends to config.extraEnv.

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

run "proxy_hops_defaults_to_unset" {
  command = plan

  assert {
    condition     = length(local.n8n_proxy_hops_env) == 0
    error_message = "n8n_proxy_hops should default to null and render no N8N_PROXY_HOPS, so n8n keeps its own default."
  }
}

run "proxy_hops_zero_renders_zero" {
  command = plan

  variables {
    n8n_proxy_hops = 0
  }

  assert {
    condition     = length(local.n8n_proxy_hops_env) == 1 && local.n8n_proxy_hops_env[0].value == "0"
    error_message = "n8n_proxy_hops = 0 must be accepted and render N8N_PROXY_HOPS=0."
  }
}

run "proxy_hops_accepts_in_range_value" {
  command = plan

  variables {
    n8n_proxy_hops = 2
  }

  assert {
    condition     = length(local.n8n_proxy_hops_env) == 1 && local.n8n_proxy_hops_env[0].name == "N8N_PROXY_HOPS" && local.n8n_proxy_hops_env[0].value == "2"
    error_message = "n8n_proxy_hops = 2 must render N8N_PROXY_HOPS=2."
  }
}

run "proxy_hops_accepts_long_chain" {
  command = plan

  variables {
    n8n_proxy_hops = 12
  }

  assert {
    condition     = length(local.n8n_proxy_hops_env) == 1 && local.n8n_proxy_hops_env[0].value == "12"
    error_message = "There is no upper bound beyond a whole number of 0 or more."
  }
}

run "proxy_hops_rejects_negative" {
  command = plan
  variables { n8n_proxy_hops = -1 }
  expect_failures = [var.n8n_proxy_hops]
}

run "proxy_hops_rejects_fractional" {
  command = plan
  variables { n8n_proxy_hops = 1.5 }
  expect_failures = [var.n8n_proxy_hops]
}

run "proxy_hops_rejects_extra_env_collision_while_set" {
  command = plan

  variables {
    n8n_proxy_hops = 2
    n8n_extra_env = [
      { name = "N8N_PROXY_HOPS", value = "1" },
    ]
  }

  expect_failures = [var.n8n_proxy_hops]
}

run "proxy_hops_rejects_worker_extra_env_collision_while_set" {
  command = plan

  variables {
    n8n_proxy_hops = 2
    n8n_worker_extra_env = [
      { name = "N8N_PROXY_HOPS", value = "1" },
    ]
  }

  expect_failures = [var.n8n_proxy_hops]
}

run "proxy_hops_rejects_worker_pool_extra_env_collision_while_set" {
  command = plan

  variables {
    n8n_proxy_hops = 2
    n8n_worker_pools = [
      {
        name      = "heavy"
        extra_env = [{ name = "N8N_PROXY_HOPS", value = "1" }]
      },
    ]
  }

  expect_failures = [var.n8n_proxy_hops]
}

run "extra_env_may_still_set_proxy_hops_when_input_unset" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_PROXY_HOPS", value = "1" },
    ]
  }

  assert {
    condition     = length(local.n8n_proxy_hops_env) == 0
    error_message = "The escape hatch must stay usable while n8n_proxy_hops is null, with no module-rendered N8N_PROXY_HOPS."
  }
}
