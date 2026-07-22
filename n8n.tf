# ── Encryption key ────────────────────────────────────────────────────────────

resource "random_id" "n8n_encryption_key" {
  byte_length = 32
}

# ── Task runner auth token ─────────────────────────────────────────────────────
# Generated once and stored in state. Used as the shared secret between the n8n
# task broker (port 5679) and the runner sidecars on main and worker pods.
# Only active when n8n_task_runners_enabled = true.

resource "random_password" "task_runner_token" {
  length  = 32
  special = false
}

# ── Namespace ─────────────────────────────────────────────────────────────────

resource "kubernetes_namespace" "n8n" {
  metadata {
    name = var.namespace
  }

  timeouts {
    delete = "2m"
  }

  depends_on = [google_container_node_pool.n8n]
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Multi-main needs two secrets: one for core n8n config, one for the DB password.

resource "kubernetes_secret" "n8n" {
  metadata {
    name      = "n8n-enterprise-secrets"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    N8N_ENCRYPTION_KEY = random_id.n8n_encryption_key.hex
    N8N_HOST           = local.n8n_domain
    N8N_PORT           = "5678"
    N8N_PROTOCOL       = "http"
    WEBHOOK_URL        = coalesce(var.n8n_webhook_url, "https://${local.n8n_domain}")
  }
}

resource "kubernetes_secret" "n8n_db" {
  metadata {
    name      = "n8n-enterprise-db-secret"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    # Use caller-supplied password when an external DB is provided, otherwise use the generated one.
    password = var.create_database ? random_password.db_password.result : var.db_password
  }
}

# GCS HMAC secret access key for the S3-compatible binary-data driver. The chart
# reads it via s3.auth.secretAccessKeySecret (a Secret ref, not a plaintext value).
# Skipped when the caller supplies an existing Secret (gcs_hmac_secret_name); see
# the BYO-HMAC locals in gcs.tf.
resource "kubernetes_secret" "n8n_s3" {
  count = local.manage_s3_secret ? 1 : 0

  metadata {
    name      = "n8n-s3-secret"
    namespace = kubernetes_namespace.n8n.metadata[0].name
  }

  data = {
    accessSecret = local.s3_secret_value
  }
}

# ── Helm release ──────────────────────────────────────────────────────────────

resource "helm_release" "n8n" {
  name            = "n8n"
  repository      = "oci://ghcr.io/n8n-io/n8n-helm-chart"
  chart           = "n8n"
  version         = var.n8n_chart_version
  namespace       = kubernetes_namespace.n8n.metadata[0].name
  wait            = true
  timeout         = var.n8n_helm_timeout
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode(merge({
    license = {
      enabled       = true
      activationKey = var.n8n_license_key
    }

    multiMain = {
      enabled  = true
      replicas = 2
      antiAffinity = {
        type = "preferred"
      }
    }

    queueMode = {
      enabled            = true
      workerReplicaCount = 2
      workerConcurrency  = var.n8n_worker_concurrency
    }

    webhookProcessor = {
      enabled                                = true
      replicaCount                           = 2
      disableProductionWebhooksOnMainProcess = true
    }

    database = {
      type        = "postgresdb"
      useExternal = true
      # Module-managed Cloud SQL (private IP over PSA) when create_database = true,
      # otherwise the caller-supplied db_host (external DB or in-cluster pooler).
      host     = var.create_database ? google_sql_database_instance.n8n.private_ip_address : var.db_host
      port     = 5432
      database = var.db_name
      schema   = "public"
      user     = var.db_username
      passwordSecret = {
        name = kubernetes_secret.n8n_db.metadata[0].name
        key  = "password"
      }
    }

    # Memorystore BASIC has transit encryption disabled. When
    # memorystore_auth_enabled = true, the AUTH string is supplied via a Secret
    # (keda.tf creates kubernetes_secret.redis_auth); otherwise no password.
    redis = merge({
      enabled     = true
      useExternal = true
      host        = google_redis_instance.n8n.host
      port        = 6379
      tls         = false
      }, var.memorystore_auth_enabled ? {
      passwordSecret = {
        name = kubernetes_secret.redis_auth[0].metadata[0].name
        key  = "password"
      }
    } : {})

    # GCS via the S3-compatible endpoint. n8n's binary-data driver is
    # S3-compatible; point it at storage.googleapis.com (s3.bucket.host) with the
    # bucket's HMAC key as the access key. autoDetect is off (that path is for
    # ambient cloud credentials); the secret is supplied via a k8s Secret ref,
    # path-style URLs.
    # Schema per the chart's values.yaml (n8n-io/n8n-hosting charts/n8n).
    s3 = {
      enabled = true
      bucket = {
        name   = google_storage_bucket.n8n.name
        region = "auto"
        host   = "storage.googleapis.com"
      }
      auth = {
        autoDetect  = false
        accessKeyId = local.hmac_access_id
        secretAccessKeySecret = {
          name = local.s3_secret_name
          key  = "accessSecret"
        }
      }
      storage = {
        mode           = "s3"
        availableModes = "filesystem,s3"
        forcePathStyle = true
      }
    }

    # The n8n pods run as this KSA, annotated for Workload Identity so
    # the workload authenticates to GCP APIs (e.g. Cloud SQL) with no static key.
    # (GCS is the exception: it uses the HMAC key above, not Workload Identity.)
    serviceAccount = {
      create = true
      name   = var.k8s_service_account_name
      annotations = {
        "iam.gke.io/gcp-service-account" = google_service_account.n8n.email
      }
    }

    secretRefs = {
      existingSecret = kubernetes_secret.n8n.metadata[0].name
    }

    # ClusterIP so the gce Ingress uses container-native load balancing (NEGs
    # target pods directly); GKE auto-adds the cloud.google.com/neg
    # annotation for Ingress-referenced ClusterIP Services on VPC-native clusters.
    # The BackendConfig annotation attaches session affinity + health check
    # (crds.tf). NOTE: this annotates the main n8n Service; if the chart does not
    # propagate it to the webhook-processor Service, that one needs the same
    # cloud.google.com/backend-config annotation applied post-deploy (smoke-test
    # follow-up).
    service = {
      type = "ClusterIP"
      port = 5678
      annotations = {
        "cloud.google.com/backend-config" = jsonencode({ default = "n8n-backendconfig" })
      }
    }

    hpa = {
      main = {
        enabled                        = true
        minReplicas                    = var.n8n_main_hpa_min_replicas
        maxReplicas                    = var.n8n_main_hpa_max_replicas
        targetCPUUtilizationPercentage = var.n8n_main_hpa_cpu_threshold
      }
      webhookProcessor = {
        enabled                        = true
        minReplicas                    = var.n8n_webhook_hpa_min_replicas
        maxReplicas                    = var.n8n_webhook_hpa_max_replicas
        targetCPUUtilizationPercentage = var.n8n_webhook_hpa_cpu_threshold
      }
    }

    # ── KEDA: queue-depth autoscaling for workers ─────────────────────────────
    # Scales workers based on Redis queue depth rather than CPU, workers appear
    # only when there are jobs and scale in proportion to backlog.
    # Two triggers: bull:jobs:wait (queued jobs) + bull:jobs:active (jobs held by
    # workers waiting for a task runner). KEDA takes the MAX of both.
    # Webhook processor HPA is created externally in scaling.tf (chart skips it
    # when keda.enabled = true).
    keda = {
      enabled = true
      worker = {
        pollingInterval = 15
        cooldownPeriod  = 60
        minReplicaCount = var.n8n_worker_keda_min_replicas
        maxReplicaCount = var.n8n_worker_keda_max_replicas
        # authenticationRef is only attached when Redis AUTH is on; an empty
        # ref name is not a valid ScaledObject trigger, so the key is omitted
        # entirely (rather than set to "") when auth is disabled.
        triggers = [
          for queue in ["bull:jobs:wait", "bull:jobs:active"] : merge(
            {
              type = "redis"
              metadata = {
                address    = "${google_redis_instance.n8n.host}:6379"
                listName   = queue
                listLength = tostring(var.n8n_worker_keda_jobs_per_replica)
              }
            },
            var.memorystore_auth_enabled ? {
              authenticationRef = { name = "n8n-redis-auth" }
            } : {}
          )
        ]
      }
    }

    resources = {
      main = {
        requests = { cpu = var.n8n_main_cpu_request, memory = var.n8n_main_memory_request }
        limits   = { cpu = var.n8n_main_cpu_limit, memory = var.n8n_main_memory_limit }
      }
      worker = {
        requests = { cpu = var.n8n_worker_cpu_request, memory = var.n8n_worker_memory_request }
        limits   = { cpu = var.n8n_worker_cpu_limit, memory = var.n8n_worker_memory_limit }
      }
      webhookProcessor = {
        requests = { cpu = var.n8n_webhook_cpu_request, memory = var.n8n_webhook_memory_request }
        limits   = { cpu = var.n8n_webhook_cpu_limit, memory = var.n8n_webhook_memory_limit }
      }
    }

    executions = {
      timeout     = var.n8n_execution_timeout
      timeoutMax  = var.n8n_execution_timeout_max
      concurrency = { productionLimit = var.n8n_execution_concurrency_limit }
      data = {
        saveOnError          = "all"
        saveOnSuccess        = "all"
        saveOnProgress       = false
        saveManualExecutions = true
      }
      pruning = {
        enabled            = true
        maxAge             = var.n8n_pruning_max_age
        maxCount           = var.n8n_pruning_max_count
        hardDeleteBuffer   = 1
        hardDeleteInterval = 15
        softDeleteInterval = 60
      }
    }

    config = {
      timezone = var.n8n_timezone
      extraEnv = concat(
        # Direct connections to Cloud SQL over private IP use SSL with a Google CA that Node.js
        # does not trust by default, so cert verification is skipped within the VPC. Set
        # db_postgresdb_ssl_enabled = false when n8n's DB host is an in-cluster pooler (e.g.
        # PgBouncer) that handles SSL on its upstream leg.
        var.db_postgresdb_ssl_enabled ? [
          { name = "DB_POSTGRESDB_SSL_ENABLED", value = "true" },
          { name = "DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED", value = "false" },
          ] : [
          { name = "DB_POSTGRESDB_SSL_ENABLED", value = "false" },
        ],
        [
          { name = "N8N_LOG_LEVEL", value = var.n8n_log_level },
          # N8N_LOG_OUTPUT controls *where* logs go (console / file), not their
          # format. Setting it to anything other than "console" / "file" / a
          # comma-separated combination leaves Winston without a transport, at
          # which point every log line is replaced with a Winston warning and
          # the actual logs are silently dropped. See variable description.
          { name = "N8N_LOG_OUTPUT", value = var.n8n_log_output },
          { name = "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS", value = "true" },
          # Override the internally computed http://host:5678 URL so webhooks show the correct HTTPS address.
          { name = "WEBHOOK_URL", value = coalesce(var.n8n_webhook_url, "https://${local.n8n_domain}") },
          { name = "N8N_RUNNERS_TASK_REQUEST_TIMEOUT", value = tostring(var.n8n_task_runner_request_timeout) },
          # Keeps Memorystore from dropping idle Redis subscriber connections under sustained load.
          # Without this, Bull detects dropped connections, emits queue errors, and pods crash.
          { name = "QUEUE_BULL_REDIS_KEEP_ALIVE", value = "true" },
          { name = "DB_POSTGRESDB_POOL_SIZE", value = tostring(var.db_postgresdb_pool_size) },
        ],
        # n8n exposes Prometheus metrics on /metrics over its HTTP port (5678) when
        # N8N_METRICS is set. The pinned chart version exposes no metrics /
        # serviceMonitor block (verified via `helm show values` against
        # var.n8n_chart_version), so the toggle is env-var-only, omit the var
        # entirely when disabled so n8n's own defaults apply (prefix, default
        # process metrics, etc). Scrape config is the caller's job.
        var.n8n_metrics_enabled ? [
          { name = "N8N_METRICS", value = "true" },
        ] : [],
        # Community-package handling. Both map straight to the n8n env vars and
        # default to n8n's own behavior (env var omitted), so only an explicit
        # opt-in changes anything. N8N_REINSTALL_MISSING_PACKAGES is what makes
        # workers reinstall UI-installed community nodes after they are
        # rescheduled onto a fresh, empty filesystem, without it those nodes
        # load on main but fail on workers in queue mode.
        var.n8n_reinstall_missing_packages ? [
          { name = "N8N_REINSTALL_MISSING_PACKAGES", value = "true" },
        ] : [],
        var.n8n_community_packages_prevent_loading ? [
          { name = "N8N_COMMUNITY_PACKAGES_PREVENT_LOADING", value = "true" },
        ] : [],

        # n8n feature toggles: templates and personalization. Only set the env
        # var when disabled (false) to override n8n's defaults. When enabled
        # (true), the env var is omitted so n8n's defaults apply.
        !var.n8n_templates_enabled ? [
          { name = "N8N_TEMPLATES_ENABLED", value = "false" },
        ] : [],
        !var.n8n_personalization_enabled ? [
          { name = "N8N_PERSONALIZATION_ENABLED", value = "false" },
        ] : [],

        # n8n OpenTelemetry tracing. config.extraEnv applies to every n8n
        # container in the multi-main topology (main, worker, webhook
        # processor), which matches the OTEL docs' queue-mode requirement
        # (https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/).
        #
        # Master switch first; each individual tuning var is null-default and
        # only emitted when explicitly set, so n8n's own defaults apply
        # otherwise. When n8n_otel_enabled = false the whole block collapses
        # to [] and no N8N_OTEL_* env vars are set on the pods.
        var.n8n_otel_enabled ? concat(
          [{ name = "N8N_OTEL_ENABLED", value = "true" }],
          var.n8n_otel_exporter_otlp_endpoint == null ? [] : [
            { name = "N8N_OTEL_EXPORTER_OTLP_ENDPOINT", value = var.n8n_otel_exporter_otlp_endpoint },
          ],
          var.n8n_otel_exporter_otlp_headers == null ? [] : [
            { name = "N8N_OTEL_EXPORTER_OTLP_HEADERS", value = var.n8n_otel_exporter_otlp_headers },
          ],
          var.n8n_otel_exporter_service_name == null ? [] : [
            { name = "N8N_OTEL_EXPORTER_SERVICE_NAME", value = var.n8n_otel_exporter_service_name },
          ],
          var.n8n_otel_traces_sample_rate == null ? [] : [
            { name = "N8N_OTEL_TRACES_SAMPLE_RATE", value = tostring(var.n8n_otel_traces_sample_rate) },
          ],
          var.n8n_otel_traces_include_node_spans == null ? [] : [
            { name = "N8N_OTEL_TRACES_INCLUDE_NODE_SPANS", value = tostring(var.n8n_otel_traces_include_node_spans) },
          ],
          var.n8n_otel_traces_inject_outbound == null ? [] : [
            { name = "N8N_OTEL_TRACES_INJECT_OUTBOUND", value = tostring(var.n8n_otel_traces_inject_outbound) },
          ],
          var.n8n_otel_traces_production_only == null ? [] : [
            { name = "N8N_OTEL_TRACES_PRODUCTION_ONLY", value = tostring(var.n8n_otel_traces_production_only) },
          ],
        ) : [],

        # n8n Enterprise log streaming, managed declaratively via env vars
        # (settings-env-vars activation pattern, n8n >= 2.19.0). When the
        # master switch is on, n8n reapplies the destinations on every startup
        # and locks the Log Streaming UI read-only. The destinations list is
        # JSON-encoded, n8n expects a JSON array in
        # N8N_LOG_STREAMING_DESTINATIONS. When the master switch is off the
        # block collapses to [] and destinations stay UI-managed.
        var.n8n_log_streaming_managed_by_env ? concat(
          [{ name = "N8N_LOG_STREAMING_MANAGED_BY_ENV", value = "true" }],
          length(var.n8n_log_streaming_destinations) > 0 ? [
            { name = "N8N_LOG_STREAMING_DESTINATIONS", value = jsonencode(var.n8n_log_streaming_destinations) },
          ] : [],
        ) : [],

        # Caller-supplied escape hatch, appended last. Kubernetes resolves
        # duplicate env names last-wins, so this would override anything above
        # it; var.n8n_extra_env is validated against local.n8n_managed_env_names
        # and local.n8n_managed_env_prefixes (variables.tf) so it cannot shadow a
        # module- or chart-managed connection/identity/storage/license var.
        var.n8n_extra_env
      )
    }

    # ── Graceful shutdown ─────────────────────────────────────────────────────
    # preStop sleep drains the pod from load balancer backends before SIGTERM.
    # terminationGracePeriodSeconds gives in-flight executions time to complete.
    lifecycle = {
      main = {
        terminationGracePeriodSeconds = var.n8n_termination_grace_period
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
      worker = {
        terminationGracePeriodSeconds = var.n8n_termination_grace_period
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
      webhookProcessor = {
        terminationGracePeriodSeconds = var.n8n_termination_grace_period
        preStop = {
          enabled = true
          command = ["/bin/sh", "-c", "sleep ${var.n8n_prestop_sleep}"]
        }
      }
    }

    # ── Task runners ─────────────────────────────────────────────────────────
    # When enabled, a sidecar container (n8nio/runners) is added to both main and
    # worker pods to execute JavaScript and Python code in isolation from the n8n
    # process. The n8n container runs a task broker on port 5679; each sidecar
    # connects to it over localhost using the auto-generated auth token.
    taskRunners = {
      enabled = var.n8n_task_runners_enabled
      authToken = {
        value = random_password.task_runner_token.result
      }
      broker = {
        listenAddress = "0.0.0.0"
        port          = 5679
      }
      launcher = {
        logLevel            = "info"
        autoShutdownTimeout = var.n8n_task_runner_auto_shutdown_timeout
      }
      nativePythonRunner = var.n8n_task_runner_python_enabled
      resources = {
        requests = { cpu = var.n8n_task_runner_cpu_request, memory = var.n8n_task_runner_memory_request }
        limits   = { cpu = var.n8n_task_runner_cpu_limit, memory = var.n8n_task_runner_memory_limit }
      }
    }

    # ── Pod Disruption Budget ─────────────────────────────────────────────────
    # Ensures at least one main pod stays running during node drains or rollouts.
    pdb = {
      enabled      = true
      minAvailable = 1
    }
    },
    # Pin the app image only when the caller asks for it; otherwise the chart
    # default (floating `stable`) applies untouched.
    var.n8n_image_tag != null ? { image = { tag = var.n8n_image_tag } } : {},
  ))]

  depends_on = [
    google_container_node_pool.n8n,
    helm_release.keda,
    google_sql_database_instance.n8n,
    google_redis_instance.n8n,
    google_storage_hmac_key.n8n,
    google_service_account_iam_member.n8n_workload_identity,
    google_project_iam_member.n8n_cloudsql_client,
  ]
}

# ── Ingress (native GKE gce) ──────────────────────────────────────────────────
# Google Cloud L7 LB on the reserved global static IP. Session affinity + health
# check come from the BackendConfig (crds.tf) via the Service annotation; the
# HTTP->HTTPS redirect comes from the FrontendConfig (crds.tf). TLS depends on
# tls_mode: managed-cert annotation, pre-shared cert annotation, or a
# spec.tls Secret.

resource "kubernetes_ingress_v1" "n8n" {
  metadata {
    name      = "n8n-ingress"
    namespace = kubernetes_namespace.n8n.metadata[0].name
    annotations = merge(
      {
        "kubernetes.io/ingress.class"                 = "gce"
        "kubernetes.io/ingress.global-static-ip-name" = google_compute_global_address.lb.name
        "networking.gke.io/v1beta1.FrontendConfig"    = "n8n-frontendconfig"
      },
      var.tls_mode == "google_managed" ? {
        "networking.gke.io/managed-certificates" = "n8n-managed-cert"
      } : {},
      local.tls_preshared ? {
        "ingress.gcp.kubernetes.io/pre-shared-cert" = google_compute_ssl_certificate.n8n[0].name
      } : {},
    )
  }

  spec {
    rule {
      host = local.n8n_domain
      http {
        # Webhook traffic must go to the dedicated webhook-processor.
        # Production webhooks are disabled on main pods (disableProductionWebhooksOnMainProcess=true).
        path {
          path      = "/webhook"
          path_type = "Prefix"
          backend {
            service {
              name = "n8n-webhook-processor"
              port { number = 5678 }
            }
          }
        }
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "n8n-main"
              port { number = 5678 }
            }
          }
        }
      }
    }

    # tls_mode = secret: the gce Ingress consumes an external k8s TLS Secret
    # (e.g. cert-manager output in examples/cloudflare). Other modes attach the
    # cert via the annotations above, so no spec.tls block.
    dynamic "tls" {
      for_each = var.tls_mode == "secret" ? [1] : []
      content {
        hosts       = [local.n8n_domain]
        secret_name = var.tls_secret_name
      }
    }
  }

  wait_for_load_balancer = true

  timeouts {
    create = "15m"
    delete = "5m"
  }

  depends_on = [
    helm_release.n8n,
    kubectl_manifest.backendconfig,
    kubectl_manifest.frontendconfig,
    time_sleep.wait_for_lb_cleanup,
  ]
}

# ── Destroy-time pause ────────────────────────────────────────────────────────
# After the Ingress is deleted, GKE begins deprovisioning the Google Cloud L7 LB
# (forwarding rules, target proxies, backend services). That teardown is
# asynchronous and can linger for 30-60s. This pause lets GCP release those
# resources before Terraform moves on to deleting the namespace and cluster.
#
# Dependency chain (create order, reversed for destroy):
#   namespace -> time_sleep -> ingress
# Destroy order (reversed):
#   1. kubernetes_ingress_v1.n8n       (Ingress deleted, LB teardown starts)
#   2. time_sleep.wait_for_lb_cleanup  (pauses 60s for LB resource release)
#   3. kubernetes_namespace.n8n        (namespace deleted, resources fully gone)

resource "time_sleep" "wait_for_lb_cleanup" {
  destroy_duration = "60s"

  depends_on = [kubernetes_namespace.n8n]
}

# ── OpenTelemetry diagnostic check ─────────────────────────────────────────
# Warns at plan time when any n8n_otel_* tuning variable is set while the
# master toggle n8n_otel_enabled is false. The OTEL wiring above collapses
# the entire N8N_OTEL_* env-var block to [] when the master is off, silent
# by design, so without this check a caller who sets, e.g.,
# n8n_otel_exporter_otlp_endpoint without also flipping n8n_otel_enabled
# would wonder why no traces are flowing.
#
# `check` block (Terraform 1.5+) emits a warning, not an error, so plan and
# apply still succeed. This is intentional: some callers will legitimately
# stage tuning config in tfvars before flipping the master switch.

check "otel_tuning_requires_master_switch" {
  assert {
    condition = var.n8n_otel_enabled || (
      var.n8n_otel_exporter_otlp_endpoint == null &&
      var.n8n_otel_exporter_otlp_headers == null &&
      var.n8n_otel_exporter_service_name == null &&
      var.n8n_otel_traces_sample_rate == null &&
      var.n8n_otel_traces_include_node_spans == null &&
      var.n8n_otel_traces_inject_outbound == null &&
      var.n8n_otel_traces_production_only == null
    )
    error_message = "One or more n8n_otel_* tuning variables are set, but n8n_otel_enabled is false, the tuning values will be ignored and no N8N_OTEL_* env vars will be set on the n8n pods. Set n8n_otel_enabled = true to apply them, or clear the tuning variables to silence this warning."
  }
}

# Same warning pattern for log streaming: destinations without the master
# switch are silently ignored by the wiring above (the env-var block collapses
# to []), so surface that at plan time as a non-blocking warning.

check "log_streaming_destinations_require_managed_by_env" {
  assert {
    condition = var.n8n_log_streaming_managed_by_env || (
      length(var.n8n_log_streaming_destinations) == 0
    )
    error_message = "n8n_log_streaming_destinations is set, but n8n_log_streaming_managed_by_env is false, the destinations will be ignored and no N8N_LOG_STREAMING_* env vars will be set on the n8n pods. Set n8n_log_streaming_managed_by_env = true to apply them, or clear the destinations to silence this warning."
  }
}
