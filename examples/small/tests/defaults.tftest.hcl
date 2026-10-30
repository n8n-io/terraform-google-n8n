# Plan-time tests for the small example using mocked providers.
#
# Exercises the module wiring without contacting Google Cloud.
#
# Run: terraform test
#   (from examples/small/ - requires terraform >= 1.13)

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}

variables {
  project_id      = "test-project"
  n8n_fqdn        = "n8n.test.example.com"
  n8n_license_key = "test-license-key-not-real"
}

run "defaults_produce_valid_plan" {
  command = plan

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "the module must serve n8n at https://<n8n_fqdn>"
  }
}

run "single_main_floor_produces_valid_plan" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "n8n_main_hpa_min_replicas=1 (single-main) must still produce a valid plan through this example's passthrough."
  }
}

run "backup_tuning_and_additional_domains_passthrough" {
  command = plan

  variables {
    postgres_backup_retained_backups        = 14
    postgres_transaction_log_retention_days = 3
    n8n_additional_domains                  = ["alt.example.com"]
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "New backup-tuning and additional-domains passthrough must not break the base plan."
  }
}

# The offline certificate path through this example: the example's
# n8n_license_key default ("") must be dropped to null, or the module's
# exactly-one-license-credential validation would reject the plan. A
# non-empty key alongside the certificate is passed through unchanged and
# rejected by that validation; the root suite covers that rejection
# (tests/kubernetes_ownership.tftest.hcl), because a run here cannot list a
# child module's variable in expect_failures.
run "license_cert_secret_ref_passthrough" {
  command = plan

  variables {
    n8n_license_key             = ""
    n8n_license_cert_secret_ref = { name = "n8n-license-cert" }
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "n8n_license_cert_secret_ref with the default empty n8n_license_key must produce a valid plan through this example's passthrough."
  }
}

# Smoke test for the TLS proxy passthroughs (n8n_extra_ca_pem, n8n_proxy_hops,
# n8n_extra_env). It proves that non-default values, including a sensitive
# n8n_extra_env, pass the module's validations and produce a valid plan. It
# does not prove that the values reach the pods: the module exposes no output
# that reflects them, and helm_release.n8n.values is unknown at plan time under
# mocks. The root suites (tests/extra_ca.tftest.hcl, tests/proxy_hops.tftest.hcl)
# cover the module-side contract. To verify forwarding, inspect the resolved
# Helm values; to verify container configuration, render the chart or inspect
# the deployed pods.
run "tls_proxy_passthrough_produces_valid_plan" {
  command = plan

  variables {
    n8n_extra_ca_pem = "-----BEGIN CERTIFICATE-----\nMIIBproxycaA\n-----END CERTIFICATE-----\n"
    n8n_proxy_hops   = 3
    n8n_extra_env = [
      { name = "HTTPS_PROXY", value = "http://proxy.corp.example:3128" },
      { name = "HTTP_PROXY", value = "http://proxy.corp.example:3128" },
      { name = "NO_PROXY", value = "localhost,127.0.0.1,.svc,.cluster.local,.googleapis.com,metadata.google.internal" },
    ]
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "Non-default TLS proxy passthrough values must produce a valid plan through this example."
  }
}
