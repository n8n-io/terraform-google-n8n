# ── Public and private HTTPS ingress rules (task 22.1) ─────────────────────────
# Two separate kubernetes_ingress_v1 resources, one per exposure boundary,
# each routing to this example's own exposure-specific Services
# (services.tf) rather than the chart-owned n8n-main/n8n-webhook-processor
# Services directly, so each boundary keeps its own BackendConfig (health
# check plus, for the private ingress, session affinity for the editor's
# WebSocket/push connections).
#
# Route contract reused from the module's own outputs (n8n_webhook_route_
# prefixes / n8n_main_route_prefixes), not duplicated here, so a chart
# upgrade that changes the webhook family list changes both the module's own
# managed ingress and this example together.

# Public: webhook families only. No editor/API route exists on this ingress
# at all, so there is no catch-all path that could ever reach main.
resource "kubernetes_ingress_v1" "public" {
  metadata {
    name      = "n8n-split-public-ingress"
    namespace = module.n8n.n8n_kube_namespace
    annotations = {
      "kubernetes.io/ingress.class"                 = "gce"
      "kubernetes.io/ingress.global-static-ip-name" = google_compute_global_address.public.name
      "networking.gke.io/managed-certificates"      = "n8n-split-public-managed-cert"
    }
  }

  spec {
    rule {
      host = var.public_webhook_fqdn

      http {
        dynamic "path" {
          for_each = module.n8n.n8n_webhook_route_prefixes
          iterator = route
          content {
            path      = route.value
            path_type = "Prefix"
            backend {
              service {
                name = kubernetes_service_v1.webhook_public.metadata[0].name
                port { number = module.n8n.n8n_service_port }
              }
            }
          }
        }
      }
    }
  }

  depends_on = [kubectl_manifest.public_managed_certificate]
}

# Private: editor/API catch-all to main, plus the same webhook families, all
# on the internal regional address. GKE's internal Application Load Balancer
# consumes a caller-supplied TLS Secret (tls.tf), not a ManagedCertificate.
resource "kubernetes_ingress_v1" "private" {
  metadata {
    name      = "n8n-split-private-ingress"
    namespace = module.n8n.n8n_kube_namespace
    annotations = {
      "kubernetes.io/ingress.class"                   = "gce-internal"
      "kubernetes.io/ingress.regional-static-ip-name" = google_compute_address.private.name
      # HTTPS only: serving both protocols requires SHARED_LOADBALANCER_VIP.
      "kubernetes.io/ingress.allow-http" = "false"
    }
  }

  spec {
    rule {
      host = var.n8n_fqdn

      http {
        dynamic "path" {
          for_each = module.n8n.n8n_webhook_route_prefixes
          iterator = route
          content {
            path      = route.value
            path_type = "Prefix"
            backend {
              service {
                name = kubernetes_service_v1.webhook_private.metadata[0].name
                port { number = module.n8n.n8n_service_port }
              }
            }
          }
        }

        dynamic "path" {
          for_each = module.n8n.n8n_main_route_prefixes
          iterator = route
          content {
            path      = route.value
            path_type = "Prefix"
            backend {
              service {
                name = kubernetes_service_v1.main_private.metadata[0].name
                port { number = module.n8n.n8n_service_port }
              }
            }
          }
        }
      }
    }

    tls {
      hosts       = [var.n8n_fqdn]
      secret_name = kubernetes_secret_v1.private_tls.metadata[0].name
    }
  }

  depends_on = [kubernetes_secret_v1.private_tls]
}
