# Plan-time tests for the medium example using mocked providers.
#
# Exercises the module wiring without contacting Google Cloud.
#
# Run: terraform test
#   (from examples/medium/ - requires terraform >= 1.9)

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

# Boot-disk sizing and pool tuning passthrough. Resource-level wiring
# (google_container_node_pool.n8n[0].node_config[0].disk_size_gb and the
# db_postgresdb_pool_size validation boundary) is already asserted in the
# root module's own test suite; a parent example's run block can only
# address module.n8n's declared outputs, not its internal resources, so
# these runs confirm the passthrough produces a valid plan at both the
# module default and an overridden value.
run "default_boot_disk_and_pool_size_produce_valid_plan" {
  command = plan

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "the module's own defaults for gke_node_disk_size_gb (100), gke_node_disk_type (pd-balanced), and db_postgresdb_pool_size (10) must remain unchanged through this example's passthrough."
  }
}

run "overridden_boot_disk_and_pool_size_produce_valid_plan" {
  command = plan

  variables {
    gke_node_disk_size_gb   = 200
    gke_node_disk_type      = "pd-ssd"
    db_postgresdb_pool_size = 5
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "overriding gke_node_disk_size_gb, gke_node_disk_type, and db_postgresdb_pool_size through this example must still produce a valid plan."
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
