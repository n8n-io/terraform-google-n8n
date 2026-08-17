# ── KEDA Redis TriggerAuthentication ──────────────────────────────────────────
# The KEDA Helm release itself is installed by modules/controllers
# (controllers.tf). This file only wires the n8n-namespace TriggerAuthentication
# that lets KEDA authenticate to Redis whenever a password is present, whether
# that password comes from module-managed Memorystore AUTH or an external
# Redis host (direct value or existing Secret reference), and trust the private
# service CA when module-managed Memorystore TLS is enabled (see locals.tf's
# manage_redis_trigger_auth / effective_redis_password_secret_*).
#
# The ScaledObject the n8n chart creates lives in the n8n namespace, so the
# TriggerAuthentication and its backing Secret(s) must live there too.

# Managed Memorystore AUTH: wraps the generated AUTH string in a Secret so it
# can be referenced the same way as the external-password Secrets below.
resource "kubernetes_secret" "redis_auth" {
  count = var.create_redis_instance && var.redis_auth_enabled ? 1 : 0

  metadata {
    name      = "n8n-redis-auth-secret"
    namespace = local.effective_namespace
  }

  data = {
    password = google_redis_instance.n8n[0].auth_string
  }

  depends_on = [kubernetes_namespace.n8n]
}

resource "kubectl_manifest" "redis_trigger_auth" {
  count = var.n8n_worker_keda_enabled && local.manage_redis_trigger_auth ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "keda.sh/v1alpha1"
    kind       = "TriggerAuthentication"
    metadata = {
      name      = "n8n-redis-auth"
      namespace = local.effective_namespace
    }
    spec = {
      secretTargetRef = concat(
        local.effective_redis_password_secret_name != null ? [{
          parameter = "password"
          name      = local.effective_redis_password_secret_name
          key       = local.effective_redis_password_secret_key
        }] : [],
        local.manage_redis_username_secret ? [{
          parameter = "username"
          name      = kubernetes_secret.n8n_redis_username[0].metadata[0].name
          key       = "username"
        }] : [],
        local.manage_redis_tls_ca ? [
          {
            parameter = "tls"
            name      = kubernetes_secret.n8n_redis_tls[0].metadata[0].name
            key       = "tls"
          },
          {
            parameter = "ca"
            name      = kubernetes_secret.n8n_redis_tls[0].metadata[0].name
            key       = "ca.crt"
          },
        ] : []
      )
    }
  })

  depends_on = [
    module.controllers,
    kubernetes_namespace.n8n,
    kubernetes_secret.redis_auth,
    kubernetes_secret.n8n_redis,
    kubernetes_secret.n8n_redis_username,
    kubernetes_secret.n8n_redis_tls,
  ]
}
