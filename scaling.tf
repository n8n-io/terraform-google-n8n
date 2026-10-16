# ── HPA: n8n webhook processor pods (CPU-based) ───────────────────────────────
# The n8n Helm chart skips creating the webhook-processor HPA when keda.enabled
# is true. Since we always use KEDA for workers, this external HPA is always
# required to cover webhook processor scaling.

resource "kubernetes_horizontal_pod_autoscaler_v2" "n8n_webhook" {
  count = var.n8n_webhook_hpa_enabled ? 1 : 0

  metadata {
    name      = "n8n-webhook-processor"
    namespace = local.effective_namespace
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "n8n-webhook-processor"
    }

    min_replicas = var.n8n_webhook_hpa_min_replicas
    max_replicas = var.n8n_webhook_hpa_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.n8n_webhook_hpa_cpu_threshold
        }
      }
    }

    # Omitted at the default (0) so the rendered HPA relies on Kubernetes'
    # own scale-up default (stabilization_window_seconds=0, react
    # immediately) instead of an explicit behavior block. When set, the
    # policy pair below reproduces Kubernetes' own default scale-up policies
    # (4 pods or 100% every 15s, whichever is higher) unchanged, so only the
    # stabilization window differs from the implicit default.
    dynamic "behavior" {
      for_each = var.n8n_webhook_hpa_scale_up_stabilization_window_seconds > 0 ? [1] : []

      content {
        scale_up {
          stabilization_window_seconds = var.n8n_webhook_hpa_scale_up_stabilization_window_seconds
          select_policy                = "Max"

          policy {
            type           = "Pods"
            value          = 4
            period_seconds = 15
          }

          policy {
            type           = "Percent"
            value          = 100
            period_seconds = 15
          }
        }
      }
    }
  }

  depends_on = [helm_release.n8n]
}
