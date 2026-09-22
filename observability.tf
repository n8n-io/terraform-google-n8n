# ── Redis exporter (opt-in) ───────────────────────────────────────────────────
# Bull queue depth is the number an incident needs first, and n8n's own
# /metrics queue gauge is unreliable under multi-main (only the leader main
# reports it). Redis itself is the source of truth; this exporter is the
# supported way to read it from inside the cluster without installing a
# monitoring stack.
#
# Off by default (redis_exporter_enabled = false creates neither resource
# below) and independent of n8n_metrics_enabled, KEDA installation, and scaler
# ownership (redis-observability capability). It reuses the same effective
# Redis connection and exact waiting/active queue keys n8n and KEDA already
# watch (locals.tf's effective_redis_* / effective_redis_queue_keys), so it
# cannot drift onto a different endpoint or a different queue than the one
# n8n is actually running on.

resource "kubernetes_deployment_v1" "redis_exporter" {
  #checkov:skip=CKV_K8S_11:Deliberate: memory is capped (below) but CPU is not, so a CFS-throttled exporter never reports late during exactly the incident it exists to surface, and one pod without a CPU limit cannot starve a node.
  count = var.redis_exporter_enabled ? 1 : 0

  metadata {
    name      = "redis-exporter"
    namespace = local.effective_namespace
    labels = {
      "app"                          = "redis-exporter"
      "app.kubernetes.io/name"       = "redis-exporter"
      "app.kubernetes.io/component"  = "metrics"
      "app.kubernetes.io/part-of"    = "n8n"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    # One replica deliberately: two would double every counter a naive
    # Prometheus query sums, and the exporter holds no state to fail over -
    # a restart just re-reads Redis from scratch. Recreate (rather than the
    # RollingUpdate default) avoids a brief window where both the old and new
    # pod scrape behind the same Service/annotations and double-count.
    replicas = 1

    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { "app" = "redis-exporter" }
    }

    template {
      metadata {
        labels = { "app" = "redis-exporter" }

        # Annotation-based scrape convention; harmless when the cluster's
        # Prometheus uses ServiceMonitors instead, since nothing reads them.
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "9121"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        # No Kubernetes API token: the exporter only ever talks to Redis and
        # answers /metrics, and it needs no Google service account either
        # (Redis-only workload, no Workload Identity grant).
        automount_service_account_token = false

        dynamic "volume" {
          for_each = local.manage_redis_tls_ca ? [1] : []
          content {
            name = "redis-ca"
            secret {
              secret_name = kubernetes_secret.n8n_redis_tls[0].metadata[0].name
              items {
                key  = "ca.crt"
                path = "ca.crt"
              }
            }
          }
        }

        container {
          name  = "redis-exporter"
          image = var.redis_exporter_image

          # rediss:// when the effective connection uses TLS, the same flag
          # n8n and KEDA read (local.effective_redis_tls_enabled), so the
          # exporter cannot end up with a different view of the endpoint.
          env {
            name  = "REDIS_ADDR"
            value = "${local.effective_redis_tls_enabled ? "rediss" : "redis"}://${local.effective_redis_host}:${local.effective_redis_port}"
          }

          # Bull queue depth, the whole reason this exporter exists. Redis
          # INFO (the default metric set) carries no per-key lengths at all,
          # so without this the exporter exports everything except the number
          # anyone turned it on for. check-single-keys names exact keys
          # (one O(1) LLEN per key per scrape), never a glob pattern that
          # could SCAN a production keyspace. The same
          # local.effective_redis_queue_keys map KEDA's ScaledObject scales
          # on, so a redis_key_prefix change moves every consumer together.
          env {
            name  = "REDIS_EXPORTER_CHECK_SINGLE_KEYS"
            value = "${local.effective_redis_queue_keys.waiting},${local.effective_redis_queue_keys.active}"
          }

          # ACL username, external Redis only (local.effective_redis_username
          # is always null for module-managed Memorystore). Not a credential,
          # so it is a literal rather than a Secret reference, matching how
          # redis.username is passed to the n8n chart.
          dynamic "env" {
            for_each = local.effective_redis_username != null ? [1] : []
            content {
              name  = "REDIS_USER"
              value = local.effective_redis_username
            }
          }

          # Same password Secret coordinates n8n's redis.passwordSecret and
          # KEDA's TriggerAuthentication reference (local.effective_redis_password_secret_*):
          # module-managed Memorystore AUTH, a direct external value wrapped
          # into a Secret, or a caller's existing Secret used as-is. The
          # module never reads the value; it only reads it at pod runtime.
          dynamic "env" {
            for_each = local.effective_redis_password_secret_name != null ? [1] : []
            content {
              name = "REDIS_PASSWORD"
              value_from {
                secret_key_ref {
                  name = local.effective_redis_password_secret_name
                  key  = local.effective_redis_password_secret_key
                }
              }
            }
          }

          # Module-managed Memorystore transit encryption presents a Google
          # service CA that is not in the image's public trust store; trust it
          # explicitly rather than disabling verification. External Redis
          # keeps using system trust and its certificate-matching host, the
          # same contract n8n and KEDA already rely on (locals.tf's
          # manage_redis_tls_ca is true only for the module-managed path).
          dynamic "env" {
            for_each = local.manage_redis_tls_ca ? [1] : []
            content {
              name  = "REDIS_EXPORTER_TLS_CA_CERT_FILE"
              value = "/etc/redis-exporter-certs/ca.crt"
            }
          }

          dynamic "volume_mount" {
            for_each = local.manage_redis_tls_ca ? [1] : []
            content {
              name       = "redis-ca"
              mount_path = "/etc/redis-exporter-certs"
              read_only  = true
            }
          }

          port {
            name           = "metrics"
            container_port = 9121
          }

          # The exporter holds no state and does no work between scrapes, so
          # these are deliberately small. Memory is capped but CPU is not: a
          # throttled exporter reports late during exactly the incident it
          # exists for, and one pod without a CPU limit cannot starve a node.
          resources {
            requests = {
              cpu    = "10m"
              memory = "32Mi"
            }
            limits = {
              memory = "64Mi"
            }
          }

          # Both probes hit /metrics rather than a dedicated health path: the
          # exporter's readiness IS its ability to answer a scrape, and it
          # answers even while Redis is unreachable (the redis_up gauge goes
          # to 0), so a Redis outage does not also delete the only thing that
          # could report it.
          liveness_probe {
            http_get {
              path = "/metrics"
              port = 9121
            }
            initial_delay_seconds = 10
            period_seconds        = 30
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          readiness_probe {
            http_get {
              path = "/metrics"
              port = 9121
            }
            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            # 59000 is the UID the upstream image already declares (USER
            # 59000:59000), matched rather than overridden so a custom
            # redis_exporter_image still starts predictably; see the
            # variable's description.
            run_as_user = 59000
            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  # Matches every other namespaced n8n resource in n8n.tf/keda.tf: an edge to
  # kubernetes_namespace.n8n on the create_namespace = true path (which itself
  # depends on google_container_node_pool.n8n), and none when the caller owns
  # the namespace.
  depends_on = [kubernetes_namespace.n8n]
}

resource "kubernetes_service_v1" "redis_exporter" {
  count = var.redis_exporter_enabled ? 1 : 0

  metadata {
    name      = "redis-exporter"
    namespace = local.effective_namespace
    labels = {
      "app"                          = "redis-exporter"
      "app.kubernetes.io/name"       = "redis-exporter"
      "app.kubernetes.io/component"  = "metrics"
      "app.kubernetes.io/part-of"    = "n8n"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  spec {
    type     = "ClusterIP"
    selector = { "app" = "redis-exporter" }

    port {
      name        = "metrics"
      port        = 9121
      target_port = 9121
      protocol    = "TCP"
    }
  }

  depends_on = [kubernetes_namespace.n8n]
}
