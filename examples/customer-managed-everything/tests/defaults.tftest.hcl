# Plan-time tests for the customer-managed-everything example using mocked
# providers. Proves the example passes every customer-supplied reference
# through the module's public output contract. The root module's
# tests/ownership_interface.tftest.hcl exercises the same complete composition
# and directly asserts that every selected ownership layer has zero resources.
#
# mock_data "google_container_cluster" defaults to a compatible cluster
# (VPC-native, Workload Identity enabled, same-project pool), matching the
# root module's own gke_ownership test fixture.
#
# Run: terraform test
#   (from examples/customer-managed-everything/ - requires terraform >= 1.9)

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
  project_id = "test-project"
  n8n_fqdn   = "n8n.test.example.com"

  n8n_license_key = "test-license-key-not-real"

  existing_network_name        = "existing-vpc"
  existing_subnetwork_name     = "existing-subnet"
  existing_pods_range_name     = "existing-pods"
  existing_services_range_name = "existing-services"

  existing_gke_cluster_name              = "existing-n8n-cluster"
  existing_gke_prerequisites_attestation = true

  n8n_database_host                 = "postgres.external.example.com"
  n8n_database_password_secret_name = "external-postgres-password"

  redis_host                 = "redis.external.example.com"
  redis_password_secret_name = "external-redis-password"

  existing_gcs_bucket_name       = "external-n8n-bucket"
  gcs_hmac_service_account_email = "byo-hmac@test-project.iam.gserviceaccount.com"
  gcs_hmac_access_id             = "GOOG1EEXAMPLE"
  gcs_hmac_secret_name           = "external-gcs-hmac-secret"

  n8n_kube_namespace = "existing-n8n-namespace"
}

run "every_layer_is_customer_managed" {
  command = plan

  assert {
    condition     = module.n8n.gke_cluster_name == "existing-n8n-cluster"
    error_message = "the example must deploy onto the existing GKE cluster, not a module-managed one."
  }

  assert {
    condition     = strcontains(module.n8n.network_id, "existing-vpc")
    error_message = "the example must attach to the existing VPC, not a module-managed one."
  }

  assert {
    condition     = module.n8n.postgres_host == "postgres.external.example.com"
    error_message = "the example must use the external PostgreSQL host, not a module-managed Cloud SQL instance."
  }

  assert {
    condition     = module.n8n.redis_host == "redis.external.example.com"
    error_message = "the example must use the external Redis host, not a module-managed Memorystore instance."
  }

  assert {
    condition     = module.n8n.gcs_bucket_name == "external-n8n-bucket"
    error_message = "the example must use the existing GCS bucket, not a module-created one."
  }

  assert {
    condition     = module.n8n.n8n_kube_namespace == "existing-n8n-namespace"
    error_message = "the example must deploy into the existing namespace, not a module-created one."
  }

  assert {
    condition     = module.n8n.n8n_main_service_name == "n8n-main"
    error_message = "the route contract must expose the main service name for a caller-owned ingress."
  }

  assert {
    condition     = contains(module.n8n.n8n_webhook_route_prefixes, "/webhook")
    error_message = "the route contract must expose /webhook among the webhook route prefixes for a caller-owned ingress."
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "the module must serve n8n at https://<n8n_fqdn>"
  }
}
