# Plan-time tests for the small example using mocked providers.
#
# Exercises the module wiring without contacting Google Cloud.
#
# Run: terraform test
#   (from examples/small/ - requires terraform >= 1.11)

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
