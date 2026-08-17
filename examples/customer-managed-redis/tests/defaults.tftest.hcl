# Plan-time tests for the customer-managed-redis example using mocked
# providers.
#
# Run: terraform test
#   (from examples/customer-managed-redis/ - requires terraform >= 1.9)

mock_provider "google" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}

variables {
  project_id                 = "test-project"
  n8n_fqdn                   = "n8n.test.example.com"
  n8n_license_key            = "test-license-key-not-real"
  redis_host                 = "redis.external.example.com"
  redis_password_secret_name = "external-redis-password"
}

run "external_redis_is_used" {
  command = plan

  assert {
    condition     = module.n8n.redis_host == "redis.external.example.com"
    error_message = "the example must point n8n and KEDA at the external Redis host, not module-managed Memorystore."
  }

  assert {
    condition     = module.n8n.redis_tls_enabled == true
    error_message = "redis_tls_enabled defaults to true in this example and must flow through to the effective connection contract."
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "the module must serve n8n at https://<n8n_fqdn>"
  }
}
