# Plan-time tests for the godaddy example using mocked providers.
#
# Exercises the module + GoDaddy-DNS wiring without contacting Google Cloud or
# GoDaddy. The google/kubernetes/helm/kubectl providers are mocked. The
# godaddy-dns provider CANNOT be mocked (Terraform does not allow mock_provider
# for hyphenated provider names), so set GODADDY_API_KEY and GODADDY_API_SECRET
# to any non-empty value when running locally. No real API calls are made at
# plan time.
#
# Run: terraform test
#   (from examples/godaddy/ - requires terraform >= 1.9)

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}

variables {
  project_id         = "test-project"
  n8n_fqdn           = "n8n.test.example.com"
  n8n_license_key    = "test-license-key-not-real"
  godaddy_domain     = "test.example.com"
  godaddy_api_key    = "test-api-key-not-real"
  godaddy_api_secret = "test-api-secret-not-real"
}

run "defaults_produce_valid_plan" {
  command = plan

  # The GoDaddy A-record must resolve n8n_fqdn to the module's LB static IP.
  assert {
    condition     = godaddy-dns_record.n8n.type == "A"
    error_message = "the n8n DNS record must be an A record pointing at the LB static IP"
  }

  assert {
    condition     = godaddy-dns_record.n8n.domain == "test.example.com"
    error_message = "the n8n record must be created in var.godaddy_domain"
  }

  # Host portion of n8n_fqdn relative to the GoDaddy zone.
  assert {
    condition     = godaddy-dns_record.n8n.name == "n8n"
    error_message = "the record name must be the host label of n8n_fqdn within godaddy_domain"
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
