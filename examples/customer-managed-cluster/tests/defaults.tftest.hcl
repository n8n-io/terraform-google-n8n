# Plan-time tests for the customer-managed-cluster example using mocked
# providers.
#
# mock_data "google_container_cluster" defaults to a compatible cluster
# (VPC-native, Workload Identity enabled, same-project pool), matching the
# root module's own gke_ownership test fixture.
#
# Run: terraform test
#   (from examples/customer-managed-cluster/ - requires terraform >= 1.9)

mock_provider "google" {
  mock_data "google_container_cluster" {
    defaults = {
      endpoint        = "10.0.0.2"
      networking_mode = "VPC_NATIVE"
      master_auth = [{
        client_certificate        = ""
        client_certificate_config = []
        client_key                = ""
        cluster_ca_certificate    = "ZmFrZS1jYQ=="
      }]
      workload_identity_config = [{ workload_pool = "test-project.svc.id.goog" }]
    }
  }
}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}

variables {
  project_id                             = "test-project"
  n8n_fqdn                               = "n8n.test.example.com"
  n8n_license_key                        = "test-license-key-not-real"
  existing_gke_cluster_name              = "existing-n8n-cluster"
  existing_gke_prerequisites_attestation = true
}

run "existing_cluster_is_used" {
  command = plan

  assert {
    condition     = module.n8n.gke_cluster_name == "existing-n8n-cluster"
    error_message = "the example must deploy onto the existing GKE cluster, not a module-managed one."
  }

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
