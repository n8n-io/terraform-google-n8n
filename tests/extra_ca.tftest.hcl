# Plan-time tests for n8n_extra_ca_pem (outbound TLS-proxy / private CA trust).
#
# helm_release.n8n.values is unknown at plan time under the mock provider (see
# AGENTS.md), so the rendered mount shape is asserted against
# local.n8n_ca_bundle_* directly, and the Secret through its resource count.

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

run "extra_ca_disabled_by_default" {
  command = plan

  assert {
    condition     = local.n8n_extra_ca_enabled == false && local.n8n_ca_bundle_mount == null && local.n8n_ca_bundle_volume == null
    error_message = "No CA bundle fragments should exist while n8n_extra_ca_pem is null."
  }

  assert {
    condition     = length(kubernetes_secret_v1.n8n_ca_bundle) == 0
    error_message = "No CA bundle Secret should be created by default."
  }
}

run "extra_ca_creates_secret_and_mount" {
  command = plan

  variables {
    n8n_extra_ca_pem = "-----BEGIN CERTIFICATE-----\nMIIBproxyca\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition     = length(kubernetes_secret_v1.n8n_ca_bundle) == 1
    error_message = "A module-managed CA bundle Secret should be created."
  }

  assert {
    condition     = local.n8n_ca_bundle_mount.mountPath == "/etc/n8n-certs/ca-bundle.crt" && local.n8n_ca_bundle_mount.readOnly == true
    error_message = "The bundle should be mounted read-only at /etc/n8n-certs/ca-bundle.crt."
  }

  assert {
    condition     = local.n8n_ca_bundle_pem == "-----BEGIN CERTIFICATE-----\nMIIBproxyca\n-----END CERTIFICATE-----"
    error_message = "Without managed Redis TLS the bundle should be the caller's PEM only (trimmed)."
  }
}

run "extra_ca_with_redis_tls_merges_both" {
  command = plan

  # The Memorystore CA is a computed attribute, unknown under the mock
  # provider, so give it a known value to assert on the merge.
  override_resource {
    target          = google_redis_instance.n8n
    override_during = plan
    values = {
      server_ca_certs = [{
        cert             = "-----BEGIN CERTIFICATE-----\nMIIBredisca\n-----END CERTIFICATE-----\n"
        create_time      = "2026-01-01T00:00:00Z"
        expire_time      = "2036-01-01T00:00:00Z"
        serial_number    = "1"
        sha1_fingerprint = "00"
      }]
    }
  }

  variables {
    n8n_extra_ca_pem                 = "-----BEGIN CERTIFICATE-----\nMIIBproxyca\n-----END CERTIFICATE-----\n"
    redis_transit_encryption_enabled = true
  }

  assert {
    condition     = local.manage_redis_tls_ca == true && length(kubernetes_secret_v1.n8n_ca_bundle) == 1
    error_message = "Redis TLS and the extra CA should coexist, with one bundle Secret."
  }

  assert {
    condition     = local.n8n_ca_bundle_pem == "-----BEGIN CERTIFICATE-----\nMIIBredisca\n-----END CERTIFICATE-----\n-----BEGIN CERTIFICATE-----\nMIIBproxyca\n-----END CERTIFICATE-----"
    error_message = "The bundle must hold the Memorystore CA first, then the caller's PEM, each trimmed and newline-joined."
  }

  assert {
    condition     = local.n8n_ca_bundle_checksum == sha256(local.n8n_ca_bundle_pem) && local.n8n_ca_bundle_checksum != sha256("-----BEGIN CERTIFICATE-----\nMIIBproxyca\n-----END CERTIFICATE-----")
    error_message = "The pod-roll checksum must hash the whole bundle, so a Memorystore CA change alone rolls the pods."
  }
}

run "extra_ca_rejects_non_certificate" {
  command = plan

  variables {
    n8n_extra_ca_pem = "not a certificate"
  }

  expect_failures = [var.n8n_extra_ca_pem]
}

run "extra_ca_rejects_private_key" {
  command = plan

  variables {
    n8n_extra_ca_pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n"
  }

  expect_failures = [var.n8n_extra_ca_pem]
}

run "extra_ca_rejects_volume_name_collision" {
  command = plan

  variables {
    n8n_extra_ca_pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    n8n_extra_volumes = [{
      name       = "ca-bundle"
      config_map = { name = "x" }
    }]
  }

  expect_failures = [var.n8n_extra_ca_pem]
}

run "extra_ca_volume_name_free_when_unset" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "ca-bundle"
      config_map = { name = "x" }
    }]
  }

  assert {
    condition     = local.n8n_extra_ca_enabled == false
    error_message = "The ca-bundle volume name is reserved only while n8n_extra_ca_pem is set."
  }
}
