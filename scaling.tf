# ── Worker KEDA pause (chart keda.worker.pause / pausedReplicaCount) ─────────
# Pause is only reliable from chart 1.13.0 on the upstream repository. Charts
# before 1.12.0 do not read keda.worker.pause at all. Chart 1.12.0 reads it but
# still renders the worker Deployment's spec.replicas on every Helm upgrade, so
# a later apply while paused writes the floor back over the held count; 1.13.0
# (n8n-hosting#201) stops rendering it. The version core drops any
# +build and -prerelease suffix first, so a preview off an older line (e.g.
# examples/worker-pools' "1.11.0-preview.workerpools.1") reads as 1.11. A
# custom n8n_chart_repository is not checked, because its version numbering
# cannot be verified against upstream (same reasoning as
# local.n8n_chart_has_worker_only_runners in capacity.tf). Nested ternaries,
# because Terraform 1.9 does not short-circuit && / || (AGENTS.md).
locals {
  n8n_chart_version_core = split(".", split("-", split("+", var.n8n_chart_version)[0])[0])

  n8n_worker_keda_pause_supported = var.n8n_chart_repository != "oci://ghcr.io/n8n-io/n8n-helm-chart" ? true : (
    tonumber(local.n8n_chart_version_core[0]) > 1 ? true : (
      tonumber(local.n8n_chart_version_core[0]) < 1 ? false : tonumber(local.n8n_chart_version_core[1]) >= 13
    )
  )
}

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
