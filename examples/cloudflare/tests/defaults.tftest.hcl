# Plan-time tests for the cloudflare example using mocked providers.
#
# Exercises the module + Cloudflare-DNS wiring without contacting Google Cloud
# or Cloudflare.
#
# Run: terraform test
#   (from examples/cloudflare/ - requires terraform >= 1.9)

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}
mock_provider "cloudflare" {}

variables {
  project_id           = "test-project"
  n8n_fqdn             = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"
  cloudflare_zone_id   = "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
  cloudflare_api_token = "test-api-token-not-real"
  acme_email           = "acme@test.example.com"
}

run "defaults_produce_valid_plan" {
  command = plan

  # The Cloudflare A-record must resolve n8n_fqdn to the module's static IP.
  assert {
    condition     = cloudflare_record.n8n.type == "A"
    error_message = "the n8n DNS record must be an A record pointing at the LB static IP"
  }

  assert {
    condition     = cloudflare_record.n8n.name == "n8n.test.example.com"
    error_message = "the n8n record name must track var.n8n_fqdn"
  }

  assert {
    condition     = cloudflare_record.n8n.zone_id == "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4"
    error_message = "the n8n record must target var.cloudflare_zone_id"
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n.test.example.com"
    error_message = "the module must serve n8n at https://<n8n_fqdn>"
  }
}
