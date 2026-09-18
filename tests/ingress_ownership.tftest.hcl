# Plan-time tests for the section 11 ingress and application-scaler
# ownership: count-gating the global address, Cloud DNS record, GKE ingress,
# BackendConfig, FrontendConfig, TLS resources, and load-balancer cleanup
# delay with create_ingress; the corrected webhook/main route contract; the
# managed-ingress SSL policy and Cloud Armor source-restriction contract; and
# the independent main HPA / webhook HPA / worker KEDA scaler switches.
#
# helm_release.n8n.values is unknown at plan time under the mock provider
# (kubernetes_namespace's attributes are unknown, deferring the whole
# resource), so the chart-level hpa/keda/multiMain/queueMode/webhookProcessor
# values this section wires cannot be asserted here. This file asserts only
# the plan-known Terraform-managed resources (Ingress, HPA, BackendConfig,
# FrontendConfig, Cloud Armor policy, static IP, DNS record, TLS certs) and
# the stable service/route outputs.

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}
mock_provider "tls" {}

variables {
  project_id           = "test-project"
  gcp_region           = "us-east4"
  friendly_name_prefix = "test"
  n8n_fqdn             = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"
}

# ── Defaults create every managed ingress resource ────────────────────────────

run "defaults_create_managed_ingress_resources" {
  command = plan

  assert {
    condition     = length(google_compute_global_address.lb) == 1
    error_message = "create_ingress defaults to true and must create the global static IP."
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n) == 1
    error_message = "create_ingress defaults to true and must create the GKE ingress."
  }

  assert {
    condition     = length(kubectl_manifest.backendconfig) == 1
    error_message = "create_ingress defaults to true and must create the BackendConfig."
  }

  assert {
    condition     = length(kubectl_manifest.frontendconfig) == 1
    error_message = "create_ingress defaults to true and must create the FrontendConfig."
  }

  assert {
    condition     = length(kubectl_manifest.managed_certificate) == 1
    error_message = "tls_mode defaults to google_managed and create_ingress defaults to true, so the ManagedCertificate must be created."
  }

  assert {
    condition     = length(time_sleep.wait_for_lb_cleanup) == 1
    error_message = "create_ingress defaults to true and must create the load-balancer teardown delay."
  }

}

# ── create_ingress = false omits every managed ingress resource ──────────────

run "customer_managed_ingress_creates_no_ingress_resources" {
  command = plan

  variables {
    create_ingress = false
  }

  assert {
    condition     = length(google_compute_global_address.lb) == 0
    error_message = "create_ingress = false must not create the global static IP."
  }

  assert {
    condition     = length(google_dns_record_set.n8n) == 0
    error_message = "create_ingress = false must not create a DNS record, even with cloud_dns_zone_name set."
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n) == 0
    error_message = "create_ingress = false must not create the GKE ingress."
  }

  assert {
    condition     = length(kubectl_manifest.backendconfig) == 0
    error_message = "create_ingress = false must not create the BackendConfig."
  }

  assert {
    condition     = length(kubectl_manifest.frontendconfig) == 0
    error_message = "create_ingress = false must not create the FrontendConfig."
  }

  assert {
    condition     = length(kubectl_manifest.managed_certificate) == 0
    error_message = "create_ingress = false must not create the ManagedCertificate."
  }

  assert {
    condition     = length(time_sleep.wait_for_lb_cleanup) == 0
    error_message = "create_ingress = false must not create the load-balancer teardown delay."
  }

  assert {
    condition     = output.static_ip == null
    error_message = "static_ip must be null when create_ingress = false."
  }

  assert {
    condition     = output.lb_ingress_ip == null
    error_message = "lb_ingress_ip must be null when create_ingress = false."
  }

  assert {
    condition     = output.n8n_main_service_name == "n8n-main"
    error_message = "Service/route outputs must remain available for a customer-managed ingress."
  }
}

run "customer_managed_ingress_with_self_signed_tls_creates_no_cert_material" {
  command = plan

  variables {
    create_ingress = false
    tls_mode       = "self_signed"
  }

  # tls_mode is a managed-ingress tuning input that is ignored on this path;
  # ingress_tuning_ignored_when_existing (checks.tf) is expected to warn.
  expect_failures = [check.ingress_tuning_ignored_when_existing]

  assert {
    condition     = length(tls_private_key.self_signed) == 0
    error_message = "create_ingress = false must not generate self-signed cert material."
  }

  assert {
    condition     = length(tls_self_signed_cert.self_signed) == 0
    error_message = "create_ingress = false must not generate a self-signed cert."
  }

  assert {
    condition     = length(google_compute_ssl_certificate.n8n) == 0
    error_message = "create_ingress = false must not create the pre-shared SSL certificate."
  }
}

# ── Complete route contract ───────────────────────────────────────────────────

run "route_prefixes_cover_every_webhook_family_path" {
  command = plan

  assert {
    condition = toset(output.n8n_webhook_route_prefixes) == toset([
      "/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp",
    ])
    error_message = "n8n_webhook_route_prefixes must include every documented webhook-family route."
  }

  assert {
    condition     = toset(output.n8n_main_route_prefixes) == toset(["/"])
    error_message = "n8n_main_route_prefixes must route the remaining traffic to the main service."
  }
}

# ── Managed ingress security controls ─────────────────────────────────────────

run "source_cidrs_create_module_managed_cloud_armor_policy" {
  command = plan

  variables {
    ingress_source_cidrs = ["203.0.113.0/24", "198.51.100.0/24"]
  }

  assert {
    condition     = length(google_compute_security_policy.n8n) == 1
    error_message = "Non-empty ingress_source_cidrs must create a module-managed Cloud Armor policy."
  }

  # try(), not `length(...) > 0 && ...[0]`: Terraform does not short-circuit
  # && and the CI-pinned 1.9.x errors on indexing the empty nested block list
  # (this rule set mixes match.config and match.expr rules; see AGENTS.md).
  assert {
    condition = anytrue([
      for r in google_compute_security_policy.n8n[0].rule :
      try(contains(tolist(r.match[0].config[0].src_ip_ranges), "203.0.113.0/24"), false)
    ])
    error_message = "The allow rule must reference the supplied CIDRs."
  }

  assert {
    condition = anytrue([
      for r in google_compute_security_policy.n8n[0].rule :
      try(r.match[0].expr[0].expression == "evaluatePreconfiguredExpr('cve-canary')" && r.action == "deny(403)", false)
    ])
    error_message = "The module-managed Cloud Armor policy must deny the log4j2 CVE-2021-44228 preconfigured expression (CKV_GCP_73)."
  }
}

run "existing_cloud_armor_policy_creates_no_module_managed_policy" {
  command = plan

  variables {
    existing_cloud_armor_policy_name = "existing-armor-policy"
  }

  assert {
    condition     = length(google_compute_security_policy.n8n) == 0
    error_message = "An existing Cloud Armor policy reference must not create a module-managed policy."
  }
}

run "source_cidrs_and_existing_cloud_armor_policy_are_mutually_exclusive" {
  command = plan

  variables {
    ingress_source_cidrs             = ["203.0.113.0/24"]
    existing_cloud_armor_policy_name = "existing-armor-policy"
  }

  expect_failures = [var.existing_cloud_armor_policy_name]
}

run "ingress_tuning_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_ingress = false
    https_redirect = false
    tls_mode       = "self_signed"
  }

  expect_failures = [check.ingress_tuning_ignored_when_existing]
}

# ── Independent application scaler ownership ──────────────────────────────────

run "scaler_disabled_omits_only_that_scalers_resources" {
  command = plan

  variables {
    n8n_webhook_hpa_enabled    = false
    n8n_webhook_fixed_replicas = 4
  }

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 0
    error_message = "n8n_webhook_hpa_enabled = false must omit the webhook processor HPA."
  }
}

run "webhook_hpa_enabled_by_default" {
  command = plan

  assert {
    condition     = length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 1
    error_message = "n8n_webhook_hpa_enabled defaults to true and must create the webhook processor HPA."
  }
}

# ── Additional ingress hosts (task 20.1) ──────────────────────────────────────

run "additional_domains_default_to_canonical_host_only" {
  command = plan

  assert {
    condition     = output.n8n_ingress_hosts == ["n8n.test.example.com"]
    error_message = "n8n_ingress_hosts must default to just the canonical n8n_fqdn."
  }
}

run "additional_domains_are_normalized_to_lowercase" {
  command = plan

  variables {
    n8n_additional_domains = ["Alt.Example.com", "second.example.com"]
  }

  assert {
    condition     = output.n8n_ingress_hosts == ["n8n.test.example.com", "alt.example.com", "second.example.com"]
    error_message = "n8n_ingress_hosts must be the canonical host followed by every n8n_additional_domains entry, normalized to lowercase."
  }
}

run "additional_domains_reject_wildcards" {
  command = plan

  variables {
    n8n_additional_domains = ["*.example.com"]
  }

  expect_failures = [var.n8n_additional_domains]
}

run "additional_domains_reject_malformed_hostname" {
  command = plan

  variables {
    n8n_additional_domains = ["not a hostname"]
  }

  expect_failures = [var.n8n_additional_domains]
}

run "additional_domains_reject_case_insensitive_duplicates" {
  command = plan

  variables {
    n8n_additional_domains = ["alt.example.com", "Alt.Example.com"]
  }

  expect_failures = [var.n8n_additional_domains]
}

run "additional_domains_reject_repeat_of_canonical_hostname" {
  command = plan

  variables {
    n8n_additional_domains = ["N8N.Test.Example.com"]
  }

  expect_failures = [var.n8n_additional_domains]
}

# ── Guarded ingress annotations (task 20.1) ───────────────────────────────────

run "ingress_annotations_reject_module_owned_key" {
  command = plan

  variables {
    ingress_annotations = {
      "kubernetes.io/ingress.class" = "nginx"
    }
  }

  expect_failures = [var.ingress_annotations]
}

run "ingress_annotations_accept_non_conflicting_key" {
  command = plan

  variables {
    ingress_annotations = {
      "example.com/custom-annotation" = "value"
    }
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n) == 1
    error_message = "A non-conflicting ingress_annotations entry must not block the managed Ingress from being created."
  }
}

run "ingress_annotations_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_ingress = false
    ingress_annotations = {
      "example.com/custom-annotation" = "value"
    }
  }

  expect_failures = [check.ingress_annotations_ignored_when_existing]
}

run "ingress_annotations_are_merged_onto_the_managed_ingress" {
  command = plan

  variables {
    ingress_annotations = {
      "example.com/custom-annotation" = "value"
    }
  }

  assert {
    condition     = kubernetes_ingress_v1.n8n[0].metadata[0].annotations["example.com/custom-annotation"] == "value"
    error_message = "ingress_annotations must be merged onto the module-managed Ingress's annotations."
  }
}

# ── Alias hosts applied to routes, DNS, and TLS (task 20.2) ──────────────────

run "aliases_get_a_full_ingress_rule_each_alongside_the_canonical_host" {
  command = plan

  variables {
    n8n_additional_domains = ["alt.example.com"]
  }

  assert {
    condition     = length(kubernetes_ingress_v1.n8n[0].spec[0].rule) == 2
    error_message = "The managed Ingress must have one rule per effective ingress host (canonical + each alias)."
  }

  assert {
    condition = toset([
      for r in kubernetes_ingress_v1.n8n[0].spec[0].rule : r.host
    ]) == toset(["n8n.test.example.com", "alt.example.com"])
    error_message = "Ingress rule hosts must match n8n_ingress_hosts exactly."
  }

  assert {
    condition = alltrue([
      for r in kubernetes_ingress_v1.n8n[0].spec[0].rule :
      toset([for p in r.http[0].path : p.path]) == toset(["/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp", "/"])
    ])
    error_message = "Every ingress rule (canonical and alias) must carry the identical webhook/main route set."
  }
}

run "aliases_get_a_cloud_dns_record_each_alongside_the_canonical_record" {
  command = plan

  variables {
    n8n_additional_domains = ["alt.example.com"]
    cloud_dns_zone_name    = "example-com"
  }

  assert {
    condition     = length(google_dns_record_set.n8n) == 2
    error_message = "One Cloud DNS A-record must be created per effective ingress host."
  }

  assert {
    condition     = google_dns_record_set.n8n["n8n.test.example.com"].name == "n8n.test.example.com."
    error_message = "The canonical record must keep its stable hostname key."
  }

  assert {
    condition     = google_dns_record_set.n8n["alt.example.com"].name == "alt.example.com."
    error_message = "The alias record must be created under its own hostname key."
  }
}

run "default_canonical_dns_record_is_the_only_record_created" {
  command = plan

  variables {
    cloud_dns_zone_name = "example-com"
  }

  assert {
    condition     = length(google_dns_record_set.n8n) == 1
    error_message = "With no aliases, only the canonical DNS record must be created."
  }

  assert {
    condition     = contains(keys(google_dns_record_set.n8n), "n8n.test.example.com")
    error_message = "The canonical DNS record must be keyed by the canonical hostname."
  }
}

run "google_managed_certificate_includes_every_alias_domain" {
  command = plan

  variables {
    n8n_additional_domains = ["alt.example.com", "second.example.com"]
  }

  assert {
    condition = yamldecode(kubectl_manifest.managed_certificate[0].yaml_body).spec.domains == [
      "n8n.test.example.com", "alt.example.com", "second.example.com",
    ]
    error_message = "The ManagedCertificate must include the canonical host and every alias domain."
  }
}

run "self_signed_certificate_sans_include_every_alias_domain" {
  command = plan

  variables {
    tls_mode               = "self_signed"
    n8n_additional_domains = ["alt.example.com"]
  }

  assert {
    condition     = toset(tls_self_signed_cert.self_signed[0].dns_names) == toset(["n8n.test.example.com", "alt.example.com"])
    error_message = "The self-signed certificate's SANs must cover the canonical host and every alias domain."
  }
}

run "secret_tls_declares_every_alias_domain_as_an_ingress_host" {
  command = plan

  variables {
    tls_mode               = "secret"
    n8n_additional_domains = ["alt.example.com"]
  }

  assert {
    condition     = toset(kubernetes_ingress_v1.n8n[0].spec[0].tls[0].hosts) == toset(["n8n.test.example.com", "alt.example.com"])
    error_message = "spec.tls.hosts must cover the canonical host and every alias domain; the caller-supplied Secret certificate must cover the same hostnames out of band."
  }
}

run "google_managed_certificate_domain_limit_rejects_over_100_hosts" {
  command = plan

  variables {
    n8n_additional_domains = [for i in range(100) : "alt${i}.example.com"]
  }

  expect_failures = [var.n8n_additional_domains]
}

run "non_google_managed_tls_mode_is_not_limited_to_100_domains" {
  command = plan

  variables {
    create_ingress         = false
    tls_mode               = "secret"
    n8n_additional_domains = [for i in range(100) : "alt${i}.example.com"]
  }

  # tls_mode is a managed-ingress tuning input ignored on this path;
  # ingress_tuning_ignored_when_existing (checks.tf) is expected to warn, and
  # ingress_annotations_ignored_when_existing does not fire (no annotations
  # set here).
  expect_failures = [check.ingress_tuning_ignored_when_existing]

  assert {
    condition     = length(output.n8n_ingress_hosts) == 101
    error_message = "A non-google_managed tls_mode must not be capped at 100 domains."
  }
}

# ── Canonical URLs stay canonical with aliases configured (task 20.3) ────────
# Aliases add routing/DNS/certificate coverage only; they must never change
# the advertised canonical editor/webhook URLs (section 19's
# local.effective_webhook_url and the n8n_url output, both keyed on
# local.n8n_fqdn, not on local.n8n_effective_ingress_hosts).

run "aliases_do_not_change_the_canonical_url_output" {
  command = plan

  variables {
    n8n_additional_domains = ["alt.example.com", "second.example.com"]
  }

  assert {
    condition     = output.n8n_url == "https://n8n.test.example.com"
    error_message = "n8n_url must remain the canonical n8n_fqdn URL regardless of configured aliases."
  }

  assert {
    condition     = local.effective_webhook_url == "https://n8n.test.example.com"
    error_message = "The effective webhook URL must remain derived from the canonical n8n_fqdn, not from any alias, when n8n_webhook_url is not set."
  }

  assert {
    condition     = local.n8n_fqdn == "n8n.test.example.com"
    error_message = "local.n8n_fqdn (the editor base URL host) must remain the canonical hostname regardless of configured aliases."
  }
}

run "additional_domains_create_no_resources_when_ingress_is_customer_managed" {
  command = plan

  variables {
    create_ingress         = false
    cloud_dns_zone_name    = "example-com"
    n8n_additional_domains = ["alt.example.com"]
  }

  # create_ingress = false is a customer-managed-ingress path; cloud_dns_zone_
  # name is a managed-ingress tuning input ignored on that path
  # (ingress_tuning_ignored_when_existing, checks.tf).
  expect_failures = [check.ingress_tuning_ignored_when_existing]

  assert {
    condition     = length(kubernetes_ingress_v1.n8n) == 0
    error_message = "create_ingress = false must not create the managed Ingress even with aliases configured."
  }

  assert {
    condition     = length(google_dns_record_set.n8n) == 0
    error_message = "create_ingress = false must not create any Cloud DNS record, even with aliases and cloud_dns_zone_name configured."
  }

  assert {
    condition     = length(kubectl_manifest.managed_certificate) == 0
    error_message = "create_ingress = false must not create the ManagedCertificate even with aliases configured."
  }

  assert {
    condition     = output.n8n_ingress_hosts == ["n8n.test.example.com", "alt.example.com"]
    error_message = "n8n_ingress_hosts must still report every alias for a customer-managed ingress."
  }
}
