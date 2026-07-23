# ── GKE Ingress CRs ───────────────────────────────────────────────────────────
# The native gce Ingress is configured through Google's CRDs rather than raw
# Ingress annotations alone. Applied via the gavinbunney/kubectl provider
# because these are CRDs the module does not own the schema for:
#
#   BackendConfig   -> session affinity + health check on the backends
#   FrontendConfig  -> HTTP->HTTPS redirect at the LB
#   ManagedCertificate -> Google-managed TLS cert (tls_mode = google_managed)
#
# The n8n Services (created by the Helm chart) reference the BackendConfig via a
# cloud.google.com/backend-config annotation set in the chart values (n8n.tf).

resource "kubectl_manifest" "backendconfig" {
  yaml_body = yamlencode({
    apiVersion = "cloud.google.com/v1"
    kind       = "BackendConfig"
    metadata = {
      name      = "n8n-backendconfig"
      namespace = var.n8n_kube_namespace
    }
    spec = {
      # Session affinity pins each browser to the same main pod so WebSocket /
      # push connections survive.
      sessionAffinity = {
        affinityType         = "GENERATED_COOKIE"
        affinityCookieTtlSec = 10800
      }
      timeoutSec = 300
      healthCheck = {
        type        = "HTTP"
        requestPath = "/healthz"
        port        = 5678
      }
    }
  })

  depends_on = [kubernetes_namespace.n8n]
}

resource "kubectl_manifest" "frontendconfig" {
  yaml_body = yamlencode({
    apiVersion = "networking.gke.io/v1beta1"
    kind       = "FrontendConfig"
    metadata = {
      name      = "n8n-frontendconfig"
      namespace = var.n8n_kube_namespace
    }
    spec = {
      redirectToHttps = {
        enabled          = var.https_redirect
        responseCodeName = "MOVED_PERMANENTLY_DEFAULT"
      }
    }
  })

  depends_on = [kubernetes_namespace.n8n]
}

# Google-managed certificate (only for tls_mode = google_managed). Provisions
# once the DNS A-record points at the static IP; the Ingress references it by
# name via the networking.gke.io/managed-certificates annotation (n8n.tf).
resource "kubectl_manifest" "managed_certificate" {
  count = var.tls_mode == "google_managed" ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "networking.gke.io/v1"
    kind       = "ManagedCertificate"
    metadata = {
      name      = "n8n-managed-cert"
      namespace = var.n8n_kube_namespace
    }
    spec = {
      domains = [var.n8n_fqdn]
    }
  })

  depends_on = [kubernetes_namespace.n8n]
}
