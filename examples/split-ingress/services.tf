# ── Exposure-specific Services and BackendConfigs (task 21.2) ──────────────────
# create_ingress = false means the module creates no Ingress, BackendConfig,
# or Service annotation of its own; this example owns all three so the public
# and private ingresses (task 22) can each apply their own backend policy to
# the SAME chart-managed pods without competing for one shared Service's
# annotations.
#
# Selector labels below match the pinned n8n Helm chart's own selector
# labels exactly (chart templates/service-main.yaml and
# templates/service-webhook-processor.yaml at the version pinned by the
# module's n8n_chart_version): app.kubernetes.io/name=n8n,
# app.kubernetes.io/instance=<helm release name>, app.kubernetes.io/component
# = main | webhook-processor. The module's helm_release.n8n (n8n.tf) always
# names the release "n8n", which is also the chart's fullname when the
# release name already contains "n8n" (chart _helpers.tpl), so these values
# are not customer-tunable. Rendering tests assert this selector against the
# pinned chart's actual pod labels rather than trusting this comment alone.

locals {
  n8n_helm_release_name = "n8n"

  main_pod_selector = {
    "app.kubernetes.io/name"      = "n8n"
    "app.kubernetes.io/instance"  = local.n8n_helm_release_name
    "app.kubernetes.io/component" = "main"
  }

  webhook_pod_selector = {
    "app.kubernetes.io/name"      = "n8n"
    "app.kubernetes.io/instance"  = local.n8n_helm_release_name
    "app.kubernetes.io/component" = "webhook-processor"
  }
}

# Public BackendConfig: health check only. No session affinity: webhook
# requests are stateless and independently retryable, unlike the editor's
# WebSocket/push connections.
resource "kubectl_manifest" "backendconfig_public" {
  yaml_body = yamlencode({
    apiVersion = "cloud.google.com/v1"
    kind       = "BackendConfig"
    metadata = {
      name      = "n8n-split-public-backendconfig"
      namespace = module.n8n.n8n_kube_namespace
    }
    spec = {
      timeoutSec = 300
      healthCheck = {
        type        = "HTTP"
        requestPath = "/healthz"
        port        = module.n8n.n8n_service_port
      }
    }
  })

  depends_on = [module.n8n]
}

# Private BackendConfig: session affinity (for the editor's WebSocket/push
# connections through main) plus the same health check. Attached to both
# private Services so main and the private-routed webhook families behave
# consistently.
resource "kubectl_manifest" "backendconfig_private" {
  yaml_body = yamlencode({
    apiVersion = "cloud.google.com/v1"
    kind       = "BackendConfig"
    metadata = {
      name      = "n8n-split-private-backendconfig"
      namespace = module.n8n.n8n_kube_namespace
    }
    spec = {
      sessionAffinity = {
        affinityType         = "GENERATED_COOKIE"
        affinityCookieTtlSec = 10800
      }
      timeoutSec = 300
      healthCheck = {
        type        = "HTTP"
        requestPath = "/healthz"
        port        = module.n8n.n8n_service_port
      }
    }
  })

  depends_on = [module.n8n]
}

# Public webhook Service: selects the same webhook-processor pods the chart's
# own n8n-webhook-processor Service selects, but as a separate ClusterIP
# Service so the public Ingress (task 22) can attach the public
# BackendConfig without touching the chart-owned Service's own annotations.
# GKE auto-adds cloud.google.com/neg for any ClusterIP Service an Ingress
# references on a VPC-native cluster (n8n.tf's own Service does not set it
# explicitly either), so no NEG annotation is set here.
resource "kubernetes_service_v1" "webhook_public" {
  metadata {
    name      = "n8n-split-webhook-public"
    namespace = module.n8n.n8n_kube_namespace
    annotations = {
      "cloud.google.com/backend-config" = jsonencode({ default = kubectl_manifest.backendconfig_public.name })
    }
  }

  spec {
    type = "ClusterIP"

    selector = local.webhook_pod_selector

    port {
      name        = "http"
      port        = module.n8n.n8n_service_port
      target_port = "http"
    }
  }

  depends_on = [module.n8n]
}

# Private main Service: selects the chart's main pods for the internal
# ingress's editor/API catch-all route.
resource "kubernetes_service_v1" "main_private" {
  metadata {
    name      = "n8n-split-main-private"
    namespace = module.n8n.n8n_kube_namespace
    annotations = {
      "cloud.google.com/backend-config" = jsonencode({ default = kubectl_manifest.backendconfig_private.name })
    }
  }

  spec {
    type = "ClusterIP"

    selector = local.main_pod_selector

    port {
      name        = "http"
      port        = module.n8n.n8n_service_port
      target_port = "http"
    }
  }

  depends_on = [module.n8n]
}

# Private webhook Service: selects the same webhook-processor pods as the
# public Service above, but with the private BackendConfig, so the internal
# ingress's webhook-family routes match the public ones' path prefixes
# without sharing the public Service's backend policy.
resource "kubernetes_service_v1" "webhook_private" {
  metadata {
    name      = "n8n-split-webhook-private"
    namespace = module.n8n.n8n_kube_namespace
    annotations = {
      "cloud.google.com/backend-config" = jsonencode({ default = kubectl_manifest.backendconfig_private.name })
    }
  }

  spec {
    type = "ClusterIP"

    selector = local.webhook_pod_selector

    port {
      name        = "http"
      port        = module.n8n.n8n_service_port
      target_port = "http"
    }
  }

  depends_on = [module.n8n]
}
