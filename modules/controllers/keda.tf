# ── KEDA ──────────────────────────────────────────────────────────────────────
# Kubernetes Event-Driven Autoscaling, scales n8n workers based on Redis queue
# depth rather than CPU, so workers appear only when there is work to do.
#
# Ordering: this submodule has no opinion on when it is safe to install KEDA
# relative to node-pool capacity or when it is safe to destroy relative to
# consuming ScaledObjects. Callers order this by depending on the module call
# itself:
#
#   module "controllers" {
#     source = "./modules/controllers"
#     ...
#     depends_on = [google_container_node_pool.n8n]   # install after capacity exists
#   }
#
#   resource "helm_release" "n8n" {
#     ...
#     depends_on = [module.controllers]   # destroy n8n (and its ScaledObjects)
#   }                                     # before KEDA is uninstalled
#
# See the root module's keda.tf and n8n.tf for the concrete wiring, and
# examples/direct-use for a caller composing this submodule directly.

resource "helm_release" "keda" {
  count = var.install_keda ? 1 : 0

  name             = "keda"
  repository       = var.keda_chart_repository
  chart            = "keda"
  version          = var.keda_chart_version
  namespace        = var.keda_namespace
  create_namespace = true
  wait             = true
  timeout          = var.keda_helm_timeout
  atomic           = true
  cleanup_on_fail  = true
}
