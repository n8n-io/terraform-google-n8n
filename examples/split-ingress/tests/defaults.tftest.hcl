# Plan-time tests for the split-ingress example using mocked providers.
#
# Exercises the module + this example's split-ingress infrastructure (task
# 21) without contacting Google Cloud. The google/kubernetes/helm/kubectl
# providers are mocked, so nothing here proves a real GKE internal ALB
# reconciles, a TLS handshake succeeds, or DNS resolves; those are manual,
# post-apply checks (see README.md and docs/upgrading-n8n.md once written).
#
# Run: terraform test
#   (from examples/split-ingress/ - requires terraform >= 1.9)

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}

variables {
  project_id            = "test-project"
  n8n_fqdn              = "n8n-internal.test.example.com"
  public_webhook_fqdn   = "hooks.test.example.com"
  n8n_license_key       = "test-license-key-not-real"
  internal_tls_cert_pem = "-----BEGIN CERTIFICATE-----\ntest\n-----END CERTIFICATE-----\n"
  internal_tls_key_pem  = "-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----\n"
}

run "split_ingress_produces_valid_plan" {
  command = plan

  # The module's own managed ingress must stay off; this example owns
  # ingress, DNS, and TLS instead (network.tf, services.tf, tls.tf).
  assert {
    condition     = module.n8n.static_ip == null
    error_message = "create_ingress = false must leave the module's own static_ip null; this example provides its own addresses."
  }

  # Public/private hostnames split correctly (task 19's webhook/editor URL
  # contract, reused here rather than duplicated).
  assert {
    condition     = module.n8n.n8n_url == "https://n8n-internal.test.example.com"
    error_message = "the module must serve the editor at https://<n8n_fqdn> (the private host)."
  }

  # ── Addresses, proxy-only subnet, firewall (task 21.2) ───────────────────
  assert {
    condition     = google_compute_global_address.public.name == "split-n8n-public"
    error_message = "the public address must be named from friendly_name_prefix."
  }

  assert {
    condition     = google_compute_address.private.address_type == "INTERNAL"
    error_message = "the private ingress address must be an internal address."
  }

  assert {
    condition     = google_compute_subnetwork.proxy_only.purpose == "REGIONAL_MANAGED_PROXY"
    error_message = "the proxy-only subnet must use purpose REGIONAL_MANAGED_PROXY, required by GKE's internal Application Load Balancer."
  }

  assert {
    condition     = google_compute_subnetwork.proxy_only.role == "ACTIVE"
    error_message = "the proxy-only subnet must use role ACTIVE."
  }

  assert {
    condition     = contains(google_compute_firewall.allow_proxy_connection.source_ranges, var.proxy_only_subnet_cidr)
    error_message = "the proxy-connection firewall rule must allow traffic sourced from the proxy-only subnet."
  }

  assert {
    condition = anytrue([
      for rule in google_compute_firewall.allow_proxy_connection.allow :
      rule.protocol == "tcp" && contains(rule.ports, tostring(module.n8n.n8n_service_port))
    ])
    error_message = "the proxy-connection firewall rule must allow n8n's actual Service port, not a hardcoded one."
  }

  # ── Exposure-specific Services select the pinned chart's own pod labels,
  # not a customer-invented label scheme (task 21.2's chart-selector
  # assertion) ──────────────────────────────────────────────────────────────
  assert {
    condition = (
      kubernetes_service_v1.webhook_public.spec[0].selector["app.kubernetes.io/name"] == "n8n" &&
      kubernetes_service_v1.webhook_public.spec[0].selector["app.kubernetes.io/instance"] == "n8n" &&
      kubernetes_service_v1.webhook_public.spec[0].selector["app.kubernetes.io/component"] == "webhook-processor"
    )
    error_message = "the public webhook Service must select the chart's webhook-processor pods by the chart's own selector labels."
  }

  assert {
    condition = (
      kubernetes_service_v1.main_private.spec[0].selector["app.kubernetes.io/name"] == "n8n" &&
      kubernetes_service_v1.main_private.spec[0].selector["app.kubernetes.io/instance"] == "n8n" &&
      kubernetes_service_v1.main_private.spec[0].selector["app.kubernetes.io/component"] == "main"
    )
    error_message = "the private main Service must select the chart's main pods by the chart's own selector labels."
  }

  assert {
    condition = (
      kubernetes_service_v1.webhook_private.spec[0].selector["app.kubernetes.io/name"] == "n8n" &&
      kubernetes_service_v1.webhook_private.spec[0].selector["app.kubernetes.io/instance"] == "n8n" &&
      kubernetes_service_v1.webhook_private.spec[0].selector["app.kubernetes.io/component"] == "webhook-processor"
    )
    error_message = "the private webhook Service must select the chart's webhook-processor pods by the chart's own selector labels."
  }

  # This example's Services must not take over the chart-owned Service names
  # (n8n-main / n8n-webhook-processor), only add new, separate Services.
  assert {
    condition = (
      kubernetes_service_v1.webhook_public.metadata[0].name != module.n8n.n8n_main_service_name &&
      kubernetes_service_v1.webhook_public.metadata[0].name != module.n8n.n8n_webhook_service_name &&
      kubernetes_service_v1.main_private.metadata[0].name != module.n8n.n8n_main_service_name &&
      kubernetes_service_v1.main_private.metadata[0].name != module.n8n.n8n_webhook_service_name &&
      kubernetes_service_v1.webhook_private.metadata[0].name != module.n8n.n8n_main_service_name &&
      kubernetes_service_v1.webhook_private.metadata[0].name != module.n8n.n8n_webhook_service_name
    )
    error_message = "this example's Services must be new, separate objects from the chart-owned main/webhook-processor Services, never reusing their names."
  }

  # ── BackendConfigs (task 21.2): public has no session affinity, private
  # does, both share the same health check. ─────────────────────────────────
  assert {
    condition     = !can(yamldecode(kubectl_manifest.backendconfig_public.yaml_body).spec.sessionAffinity)
    error_message = "the public BackendConfig must not set session affinity (webhooks are stateless)."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.backendconfig_private.yaml_body).spec.sessionAffinity.affinityType == "GENERATED_COOKIE"
    error_message = "the private BackendConfig must set cookie-based session affinity for the editor's WebSocket/push connections."
  }

  # ── TLS/DNS prerequisites (task 21.3) ─────────────────────────────────────
  assert {
    condition     = kubernetes_secret_v1.private_tls.type == "kubernetes.io/tls"
    error_message = "the private ingress TLS Secret must be a kubernetes.io/tls Secret."
  }

  assert {
    condition     = yamldecode(kubectl_manifest.public_managed_certificate.yaml_body).spec.domains == [var.public_webhook_fqdn]
    error_message = "the public ManagedCertificate must cover exactly the public webhook host, not the private editor host."
  }

  # ── Ingress routing (task 22.1) ────────────────────────────────────────────
  assert {
    condition     = kubernetes_ingress_v1.public.metadata[0].annotations["kubernetes.io/ingress.class"] == "gce"
    error_message = "the public ingress must use the external gce Ingress class."
  }

  assert {
    condition     = kubernetes_ingress_v1.public.metadata[0].annotations["kubernetes.io/ingress.global-static-ip-name"] == google_compute_global_address.public.name
    error_message = "the public ingress must attach the public global static IP."
  }

  assert {
    condition     = kubernetes_ingress_v1.public.spec[0].rule[0].host == var.public_webhook_fqdn
    error_message = "the public ingress must serve the public webhook host."
  }

  assert {
    condition = alltrue([
      for path in kubernetes_ingress_v1.public.spec[0].rule[0].http[0].path :
      contains(module.n8n.n8n_webhook_route_prefixes, path.path) && path.backend[0].service[0].name == kubernetes_service_v1.webhook_public.metadata[0].name
    ])
    error_message = "every public ingress path must be one of the module's webhook route prefixes and route to the public webhook Service."
  }

  assert {
    condition     = length(kubernetes_ingress_v1.public.spec[0].rule[0].http[0].path) == length(module.n8n.n8n_webhook_route_prefixes)
    error_message = "the public ingress must route exactly the module's webhook route prefixes, no more and no fewer."
  }

  assert {
    condition = alltrue([
      for path in kubernetes_ingress_v1.public.spec[0].rule[0].http[0].path :
      path.backend[0].service[0].name != kubernetes_service_v1.main_private.metadata[0].name && path.path != "/"
    ])
    error_message = "the public ingress must contain no main backend and no catch-all path."
  }

  assert {
    condition     = kubernetes_ingress_v1.private.metadata[0].annotations["kubernetes.io/ingress.class"] == "gce-internal"
    error_message = "the private ingress must use the internal gce-internal Ingress class."
  }

  assert {
    condition     = kubernetes_ingress_v1.private.metadata[0].annotations["kubernetes.io/ingress.regional-static-ip-name"] == google_compute_address.private.name
    error_message = "the private ingress must attach the private regional internal static IP."
  }

  assert {
    condition     = kubernetes_ingress_v1.private.spec[0].rule[0].host == var.n8n_fqdn
    error_message = "the private ingress must serve the private editor host."
  }

  assert {
    condition = alltrue([
      for prefix in module.n8n.n8n_webhook_route_prefixes :
      anytrue([
        for path in kubernetes_ingress_v1.private.spec[0].rule[0].http[0].path :
        path.path == prefix && path.backend[0].service[0].name == kubernetes_service_v1.webhook_private.metadata[0].name
      ])
    ])
    error_message = "the private ingress must route every webhook family to the private webhook Service."
  }

  assert {
    condition = alltrue([
      for prefix in module.n8n.n8n_main_route_prefixes :
      anytrue([
        for path in kubernetes_ingress_v1.private.spec[0].rule[0].http[0].path :
        path.path == prefix && path.backend[0].service[0].name == kubernetes_service_v1.main_private.metadata[0].name
      ])
    ])
    error_message = "the private ingress must route the main catch-all to the private main Service."
  }

  assert {
    condition     = kubernetes_ingress_v1.private.spec[0].tls[0].secret_name == kubernetes_secret_v1.private_tls.metadata[0].name
    error_message = "the private ingress must use the caller-supplied TLS Secret."
  }

}

run "single_main_floor_produces_valid_plan" {
  command = plan

  variables {
    n8n_main_hpa_min_replicas = 1
  }

  assert {
    condition     = module.n8n.n8n_url == "https://n8n-internal.test.example.com"
    error_message = "n8n_main_hpa_min_replicas=1 (single-main) must still produce a valid plan through this example's passthrough."
  }
}
