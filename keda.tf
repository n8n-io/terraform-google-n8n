# ── KEDA ──────────────────────────────────────────────────────────────────────
# Kubernetes Event-Driven Autoscaling, scales n8n workers based on Redis queue
# depth rather than CPU, so workers appear only when there is work to do.
#
# Destroy ordering: helm_release.n8n depends_on this release, so during destroy
# the n8n release (including its ScaledObjects) is deleted FIRST while the KEDA
# operator is still running. KEDA processes the ScaledObject deletions and
# removes its own "finalizer.keda.sh" finalizer. KEDA is then uninstalled only
# after all ScaledObjects are gone (no orphaned finalizers).
#
# Install ordering: depends_on the node pool so scheduling capacity exists.
#
# Memorystore AUTH: default is auth disabled (BASIC tier), so the
# KEDA Redis triggers in n8n.tf use an empty authenticationRef. When
# memorystore_auth_enabled = true, the resources below give KEDA the AUTH string
# via a TriggerAuthentication CR, so the auth path works end-to-end rather than
# being a landmine.

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  namespace        = "keda"
  create_namespace = true
  wait             = true
  timeout          = 300
  atomic           = true
  cleanup_on_fail  = true

  depends_on = [google_container_node_pool.n8n]
}

# ── KEDA Redis AUTH (only when memorystore_auth_enabled) ──────────────────────
# The ScaledObject the n8n chart creates lives in the n8n namespace, so the
# TriggerAuthentication and its backing Secret must live there too.

resource "kubernetes_secret" "redis_auth" {
  count = var.memorystore_auth_enabled ? 1 : 0

  metadata {
    name      = "n8n-redis-auth-secret"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    password = google_redis_instance.n8n.auth_string
  }
}

resource "kubectl_manifest" "redis_trigger_auth" {
  count = var.memorystore_auth_enabled ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "TriggerAuthentication"
    metadata = {
      name      = "n8n-redis-auth"
      namespace = var.namespace
    }
    spec = {
      secretTargetRef = [{
        parameter = "password"
        name      = kubernetes_secret.redis_auth[0].metadata[0].name
        key       = "password"
      }]
    }
  })

  depends_on = [helm_release.keda, kubernetes_secret.redis_auth]
}
