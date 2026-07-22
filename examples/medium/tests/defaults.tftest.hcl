# Plan-time tests for the medium example using mocked providers.
#
# Exercises the module wiring without contacting Google Cloud.
#
# Run: terraform test
#   (from examples/medium/ - requires terraform >= 1.9)

mock_provider "google" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}

variables {
  project_id      = "test-project"
  n8n_domain      = "n8n.test.example.com"
  n8n_license_key = "test-license-key-not-real"
}

run "defaults_produce_valid_plan" {
  command = plan

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "the module must serve n8n at https://<n8n_domain>"
  }
}
