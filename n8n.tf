# ── Encryption key ────────────────────────────────────────────────────────────
# Skipped when the caller references an existing core Secret
# (existing_n8n_core_secret_name); the generated key would never be used, see
# locals.tf's manage_core_secret / effective_core_secret_name (D7).

resource "random_id" "n8n_encryption_key" {
  count = local.manage_core_secret ? 1 : 0

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
# create_namespace = false deploys into an existing namespace the module does
# not read, create, change, or delete; every namespaced resource below targets
# local.effective_namespace instead of this resource, so the ordering stays
# safe whether or not the module owns the namespace.

resource "kubernetes_namespace" "n8n" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.n8n_kube_namespace
  }

  timeouts {
    delete = "2m"
  }

  depends_on = [google_container_node_pool.n8n]
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Multi-main needs two secrets: one for core n8n config, one for the DB password.

resource "kubernetes_secret" "n8n" {
  count = local.manage_core_secret ? 1 : 0

  metadata {
    name      = "n8n-enterprise-secrets"
    namespace = local.effective_namespace
  }

  data = {
    N8N_ENCRYPTION_KEY = random_id.n8n_encryption_key[0].hex
    N8N_HOST           = local.n8n_fqdn
    N8N_PORT           = "5678"
    N8N_PROTOCOL       = "http"
    WEBHOOK_URL        = coalesce(var.n8n_webhook_url, "https://${local.n8n_fqdn}")
  }

  depends_on = [kubernetes_namespace.n8n]
}

# Skipped when the caller references an existing Secret for the external
# database password (n8n_database_password_secret_ref); see
# locals.tf's manage_db_secret / effective_db_password_secret_*.
resource "kubernetes_secret" "n8n_db" {
  count = local.manage_db_secret ? 1 : 0

  metadata {
    name      = "n8n-enterprise-db-secret"
    namespace = local.effective_namespace
  }

  data = {
    # Use caller-supplied password when an external DB is provided, otherwise use the generated one.
    password = var.create_postgres_instance ? random_password.db_password[0].result : var.n8n_database_password
  }

  depends_on = [kubernetes_namespace.n8n]
}

# Wraps a direct external Redis password (redis_password) so n8n and KEDA can
# reference it as a Secret. Skipped for module-managed Memorystore (AUTH uses
# keda.tf's kubernetes_secret.redis_auth instead) and for an existing Secret
# reference (redis_password_secret_ref, used as-is); see locals.tf's
# manage_redis_secret / effective_redis_password_secret_*.
resource "kubernetes_secret" "n8n_redis" {
  count = local.manage_redis_secret ? 1 : 0

  metadata {
    name      = "n8n-redis-secret"
    namespace = local.effective_namespace
  }

  data = {
    password = var.redis_password
  }

  depends_on = [kubernetes_namespace.n8n]
}

# Wraps the plain redis_username variable in a Secret purely so KEDA's
# TriggerAuthentication can reference it (KEDA's Redis scaler only accepts
# authenticationRef via secretTargetRef, not a plain trigger-metadata value).
# n8n itself takes redis_username as a plain chart value below.
resource "kubernetes_secret" "n8n_redis_username" {
  count = local.manage_redis_username_secret ? 1 : 0

  metadata {
    name      = "n8n-redis-username-secret"
    namespace = local.effective_namespace
  }

  data = {
    username = local.effective_redis_username
  }

  depends_on = [kubernetes_namespace.n8n]
}

# Memorystore presents a Google-managed service CA when in-transit encryption
# is enabled. Node.js and KEDA do not trust that private CA by default, so keep
# the provider-returned certificate in the workload namespace for both clients.
resource "kubernetes_secret" "n8n_redis_tls" {
  count = local.manage_redis_tls_ca ? 1 : 0

  metadata {
    name      = "n8n-redis-tls-secret"
    namespace = local.effective_namespace
  }

  data = {
    "ca.crt" = google_redis_instance.n8n[0].server_ca_certs[0].cert
    tls      = "enable"
  }

  depends_on = [kubernetes_namespace.n8n]
}

# GCS HMAC secret access key for the S3-compatible binary-data driver. The chart
# reads it via s3.auth.secretAccessKeySecret (a Secret ref, not a plaintext value).
# Skipped when the caller supplies an existing Secret (gcs_hmac_secret_name); see
# the BYO-HMAC locals in gcs.tf.
resource "kubernetes_secret" "n8n_s3" {
  count = local.manage_s3_secret ? 1 : 0

  metadata {
    name      = "n8n-s3-secret"
    namespace = local.effective_namespace
  }

  data = {
    accessSecret = local.s3_secret_value
  }

  depends_on = [kubernetes_namespace.n8n]
}

# ── n8n Kubernetes ServiceAccount (image-pull-secrets ownership) ─────────────
# Only created when var.n8n_image_pull_secrets is non-empty; otherwise the
# chart creates the account under its own name and this resource does not
# exist. See local.n8n_manages_service_account for why the module ever takes
# ownership over from the chart. Annotated for Workload Identity so the pods
# keep authenticating to GCP APIs the same way regardless of which side
# created the account.
resource "kubernetes_service_account_v1" "n8n" {
  count = local.n8n_manages_service_account ? 1 : 0

  metadata {
    name      = local.n8n_service_account_name
    namespace = local.effective_namespace
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.n8n.email
    }
  }

  automount_service_account_token = true

  dynamic "image_pull_secret" {
    for_each = var.n8n_image_pull_secrets
    content {
      name = image_pull_secret.value
    }
  }

  depends_on = [
    google_container_node_pool.n8n,
    kubernetes_namespace.n8n,
  ]
}

# ── Helm release ──────────────────────────────────────────────────────────────

resource "helm_release" "n8n" {
  name            = "n8n"
  repository      = var.n8n_chart_repository
  chart           = "n8n"
  version         = var.n8n_chart_version
  namespace       = local.effective_namespace
  wait            = true
  timeout         = var.n8n_helm_timeout
  atomic          = true
  cleanup_on_fail = true

  values = [yamlencode(merge({
    # Ownership-neutral (D7): a direct license value (activationKey) or an
    # existing Secret reference (existingSecret), never both (enforced by
    # n8n_license_key_secret_ref's mutual-exclusivity validation). Exactly one
    # of the two is ever non-empty; the chart ignores activationKey once
    # existingSecret.name is set.
    license = {
      enabled       = true
      activationKey = var.n8n_license_key_secret_ref != null ? "" : var.n8n_license_key
      existingSecret = var.n8n_license_key_secret_ref != null ? {
        name = var.n8n_license_key_secret_ref.name
        key  = var.n8n_license_key_secret_ref.key
        } : {
        name = ""
        key  = "license-key"
      }
    }

    # Fixed replica counts fall back to n8n_*_fixed_replicas when the caller
    # owns that pod's scaling (n8n_main_hpa_enabled / n8n_webhook_hpa_enabled /
    # n8n_worker_keda_enabled = false); otherwise they seed the initial
    # replica count at the scaler's own minimum, which the HPA/KEDA
    # ScaledObject immediately takes over (D9).
    multiMain = {
      enabled  = true
      replicas = local.n8n_effective_main_replica_count
      antiAffinity = {
        type = "preferred"
      }
    }

    queueMode = {
      enabled            = true
      workerReplicaCount = local.n8n_effective_worker_replica_count
      workerConcurrency  = var.n8n_worker_concurrency
    }

    webhookProcessor = {
      enabled                                = true
      replicaCount                           = local.n8n_effective_webhook_replica_count
      disableProductionWebhooksOnMainProcess = true
    }

    database = {
      type        = "postgresdb"
      useExternal = true
      # Module-managed Cloud SQL (private IP over PSA) when create_postgres_instance = true,
      # otherwise the caller-supplied n8n_database_host (external DB or in-cluster pooler).
      host     = local.effective_postgres_host
      port     = 5432
      database = var.n8n_database_name
      schema   = "public"
      user     = var.n8n_database_user
      passwordSecret = {
        name = local.effective_db_password_secret_name
        key  = local.effective_db_password_secret_key
      }
    }

    # Ownership-neutral: host/port/tls/username resolve to the module-managed
    # Memorystore instance or the supplied external redis_* inputs
    # (locals.tf). The password source (managed AUTH, external direct value,
    # or external Secret reference) is omitted entirely when none is set.
    #
    # username and prefix pass "" when unset: verified against the pinned
    # chart (1.10.1), whose templates guard both with Go-template truthiness
    # ({{- if .Values.redis.username }} / {{- if .Values.redis.prefix }} in
    # configmap.yaml and _configmap-env.tpl), so an empty string renders no
    # QUEUE_BULL_REDIS_USERNAME / QUEUE_BULL_PREFIX env var and n8n falls back
    # to its own defaults (no username, prefix "bull"). That keeps the KEDA
    # trigger list names below (local.effective_redis_key_prefix, which
    # coalesces to "bull") watching the same lists n8n writes to. Re-verify
    # these guards when bumping n8n_chart_version's default.
    redis = merge({
      enabled     = true
      useExternal = true
      host        = local.effective_redis_host
      port        = local.effective_redis_port
      tls         = local.effective_redis_tls_enabled
      username    = local.effective_redis_username != null ? local.effective_redis_username : ""
      timeout     = var.n8n_redis_timeout_threshold_ms
      prefix      = var.redis_key_prefix != null ? var.redis_key_prefix : ""
      }, local.effective_redis_password_secret_name != null ? {
      passwordSecret = {
        name = local.effective_redis_password_secret_name
        key  = local.effective_redis_password_secret_key
      }
    } : {})

    # Trust the private service CA exposed by module-managed Memorystore when
    # transit encryption is enabled. These top-level chart values apply to the
    # main, worker, and webhook-processor pods.
    extraVolumes = local.manage_redis_tls_ca ? [{
      name = "redis-ca"
      secret = {
        secretName = kubernetes_secret.n8n_redis_tls[0].metadata[0].name
        items = [{
          key  = "ca.crt"
          path = "ca.crt"
        }]
      }
    }] : []

    extraVolumeMounts = local.manage_redis_tls_ca ? [{
      name      = "redis-ca"
      mountPath = "/etc/n8n-certs/redis-ca.crt"
      subPath   = "ca.crt"
      readOnly  = true
    }] : []

    # GCS via the S3-compatible endpoint. n8n's binary-data driver is
    # S3-compatible; point it at storage.googleapis.com (s3.bucket.host) with the
    # bucket's HMAC key as the access key. autoDetect is off (that path is for
    # ambient cloud credentials); the secret is supplied via a k8s Secret ref,
    # path-style URLs.
    # Schema per the chart's values.yaml (n8n-io/n8n-hosting charts/n8n).
    s3 = {
      enabled = true
      bucket = {
        name   = local.effective_gcs_bucket_name
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
    # create is false once n8n_image_pull_secrets moves ownership of the
    # account to kubernetes_service_account_v1.n8n above (local.
    # n8n_manages_service_account); the annotation is harmless to keep set on
    # both branches since the chart only applies it when it creates the account.
    serviceAccount = {
      create = !local.n8n_manages_service_account
      name   = local.n8n_service_account_name
      annotations = {
        "iam.gke.io/gcp-service-account" = google_service_account.n8n.email
      }
    }

    secretRefs = {
      existingSecret = local.effective_core_secret_name
    }

    # ClusterIP so the gce Ingress uses container-native load balancing (NEGs
    # target pods directly); GKE auto-adds the cloud.google.com/neg
    # annotation for Ingress-referenced ClusterIP Services on VPC-native clusters.
    # The BackendConfig annotation attaches session affinity + health check
    # (crds.tf). NOTE: this annotates the main n8n Service; if the chart does not
    # propagate it to the webhook-processor Service, that one needs the same
    # cloud.google.com/backend-config annotation applied post-deploy (smoke-test
    # follow-up).
    service = merge({
      type = "ClusterIP"
      port = 5678
      }, var.create_ingress ? {
      annotations = {
        "cloud.google.com/backend-config" = jsonencode({ default = "n8n-backendconfig" })
      }
    } : {})

    hpa = {
      main = {
        enabled                        = var.n8n_main_hpa_enabled
        minReplicas                    = var.n8n_main_hpa_min_replicas
        maxReplicas                    = var.n8n_main_hpa_max_replicas
        targetCPUUtilizationPercentage = var.n8n_main_hpa_cpu_threshold
      }
      # Independent of n8n_webhook_hpa_enabled: the chart never creates a
      # webhookProcessor HPA when keda.enabled = true (below), so this stays
      # disabled here and scaling.tf's kubernetes_horizontal_pod_autoscaler_v2
      # renders the equivalent HPA externally, gated on the same switch.
      webhookProcessor = {
        enabled = false
      }
    }

    # ── KEDA: queue-depth autoscaling for workers ─────────────────────────────
    # Scales workers based on Redis queue depth rather than CPU, workers appear
    # only when there are jobs and scale in proportion to backlog.
    # Two triggers: <prefix>:jobs:wait (queued jobs) + <prefix>:jobs:active (jobs
    # held by workers waiting for a task runner), prefix synchronized with
    # redis_key_prefix (local.effective_redis_key_prefix) so KEDA watches the
    # same lists n8n's Bull queue writes to. KEDA takes the MAX of both.
    # Webhook processor HPA is created externally in scaling.tf (chart skips it
    # when keda.enabled = true).
    keda = {
      enabled = var.n8n_worker_keda_enabled
      worker = {
        pollingInterval = 15
        cooldownPeriod  = 60
        minReplicaCount = var.n8n_worker_keda_min_replicas
        maxReplicaCount = var.n8n_worker_keda_max_replicas
        # authenticationRef is attached when a Redis password is present
        # (managed AUTH or external direct/Secret-reference password) or when
        # module-managed Memorystore TLS needs its private CA trusted. An empty
        # ref name is not valid, so the key is omitted when neither applies.
        triggers = [
          for queue in [
            "${local.effective_redis_key_prefix}:jobs:wait",
            "${local.effective_redis_key_prefix}:jobs:active",
            ] : merge(
            {
              type = "redis"
              metadata = merge({
                address    = "${local.effective_redis_host}:${local.effective_redis_port}"
                listName   = queue
                listLength = tostring(var.n8n_worker_keda_jobs_per_replica)
                }, local.manage_redis_tls_ca ? {} : {
                # KEDA rejects setting TLS in both trigger metadata and a
                # TriggerAuthentication. Managed TLS uses the latter so it can
                # carry the private CA; external Redis keeps this metadata path.
                enableTLS = tostring(local.effective_redis_tls_enabled)
              })
            },
            local.manage_redis_trigger_auth ? {
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
      data        = local.n8n_executions_data
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
          { name = "WEBHOOK_URL", value = coalesce(var.n8n_webhook_url, "https://${local.n8n_fqdn}") },
          { name = "N8N_RUNNERS_TASK_REQUEST_TIMEOUT", value = tostring(var.n8n_task_runner_request_timeout) },
          # Keeps Memorystore from dropping idle Redis subscriber connections under sustained load.
          # Without this, Bull detects dropped connections, emits queue errors, and pods crash.
          { name = "QUEUE_BULL_REDIS_KEEP_ALIVE", value = "true" },
          { name = "DB_POSTGRESDB_POOL_SIZE", value = tostring(var.db_postgresdb_pool_size) },
          # n8n's upstream default (true) makes the leader main detach its floating
          # license entitlement on shutdown, zeroing the shared cert in the database.
          # In multi-main (the module default) a fresh main pod then starts as a
          # follower, never renews on init, reads the zeroed cert, and crash-loops on
          # the license gate. All mains share the same device fingerprint, so keeping
          # this false reuses a single floating seat across restarts instead of
          # releasing and re-acquiring it. Always emitted (unlike opt-in toggles)
          # because the module default deliberately overrides n8n's own default.
          { name = "N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN", value = tostring(var.n8n_license_detach_floating_on_shutdown) },
        ],
        local.manage_redis_tls_ca ? [
          { name = "NODE_EXTRA_CA_CERTS", value = "/etc/n8n-certs/redis-ca.crt" },
        ] : [],
        # Ships nodes baked into a custom image (n8n_image_repository) at this
        # path. Omitted entirely when unset, matching n8n's own default (no
        # extra scan directory).
        var.n8n_custom_extensions_path != null ? [
          { name = "N8N_CUSTOM_EXTENSIONS", value = var.n8n_custom_extensions_path },
        ] : [],
        # Execution-data offload to the effective GCS S3-compatible storage
        # contract (n8n >= 2.27, Enterprise). Reuses the same s3 block and HMAC
        # credentials already wired above for binary data; nothing else is
        # needed. Emitted only for "s3"; "database" is n8n's own default, so
        # the env var is omitted entirely there.
        var.n8n_execution_data_storage_mode == "s3" ? [
          { name = "N8N_EXECUTION_DATA_STORAGE_MODE", value = "s3" },
        ] : [],
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

        # n8n External Secrets. The master switch disables the feature
        # entirely via N8N_DISABLED_MODULES (comma-separated) when off; the
        # update interval is independent and only applied while enabled, an
        # opposite-path check below warns when it is set but ignored.
        var.n8n_external_secrets_enabled ? [] : [
          { name = "N8N_DISABLED_MODULES", value = local.n8n_disabled_modules },
        ],
        (var.n8n_external_secrets_enabled && var.n8n_external_secrets_update_interval != null) ? [
          { name = "N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL", value = tostring(var.n8n_external_secrets_update_interval) },
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
    #
    # The sidecar's repository/tag are left to the chart by default, which
    # derives the tag from the n8n application image's tag. That is correct
    # for a published n8n tag but wrong for a custom image tagged something
    # like "2.27.4-mypackages", hence the n8n_task_runner_image_tag override,
    # merged in only when set so the chart's inheritance stays the default.
    taskRunners = merge({
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
      },
      var.n8n_task_runner_image_repository == null && var.n8n_task_runner_image_tag == null ? {} : {
        image = merge(
          var.n8n_task_runner_image_repository == null ? {} : { repository = var.n8n_task_runner_image_repository },
          var.n8n_task_runner_image_tag == null ? {} : { tag = var.n8n_task_runner_image_tag },
        )
    })

    # ── Pod Disruption Budget ─────────────────────────────────────────────────
    # Ensures at least one main pod stays running during node drains or rollouts.
    pdb = {
      enabled      = true
      minAvailable = 1
    }
    },
    # Override the app image only where the caller asks for it; otherwise the
    # chart's own defaults apply untouched (docker.n8n.io/n8nio/n8n:stable).
    # Repository, tag, and pull policy are merged key by key rather than as a
    # whole `image` map so setting one does not blank the others: yamlencode
    # would emit e.g. `repository: null`, which the chart renders into an
    # unpullable `null:2.27.4` reference.
    var.n8n_image_repository == null && var.n8n_image_tag == null && var.n8n_image_pull_policy == null ? {} : {
      image = merge(
        var.n8n_image_repository == null ? {} : { repository = var.n8n_image_repository },
        var.n8n_image_tag == null ? {} : { tag = var.n8n_image_tag },
        var.n8n_image_pull_policy == null ? {} : { pullPolicy = var.n8n_image_pull_policy },
      )
    },
  ))]

  depends_on = [
    google_container_node_pool.n8n,
    kubernetes_namespace.n8n,
    module.controllers,
    google_sql_database_instance.n8n,
    google_redis_instance.n8n,
    kubernetes_secret.n8n_redis,
    kubernetes_secret.n8n_redis_username,
    kubernetes_secret.n8n_redis_tls,
    google_storage_hmac_key.n8n,
    google_service_account_iam_member.n8n_workload_identity,
    google_project_iam_member.n8n_cloudsql_client,
    kubernetes_service_account_v1.n8n, # empty list unless the module owns the account
  ]
}

# ── Ingress (native GKE gce) ──────────────────────────────────────────────────
# Google Cloud L7 LB on the reserved global static IP. Session affinity + health
# check come from the BackendConfig (crds.tf) via the Service annotation; the
# HTTP->HTTPS redirect comes from the FrontendConfig (crds.tf). TLS depends on
# tls_mode: managed-cert annotation, pre-shared cert annotation, or a
# spec.tls Secret.

resource "kubernetes_ingress_v1" "n8n" {
  count = var.create_ingress ? 1 : 0

  metadata {
    name      = "n8n-ingress"
    namespace = local.effective_namespace
    annotations = merge(
      {
        "kubernetes.io/ingress.class"                 = "gce"
        "kubernetes.io/ingress.global-static-ip-name" = google_compute_global_address.lb[0].name
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
      host = local.n8n_fqdn
      http {
        # Webhook, webhook-waiting, form, form-waiting, and mcp traffic must go
        # to the dedicated webhook-processor (local.effective_webhook_route_
        # prefixes, the same list the n8n_webhook_route_prefixes output
        # exposes for a customer-managed ingress). Production webhooks are
        # disabled on main pods (disableProductionWebhooksOnMainProcess=true).
        dynamic "path" {
          for_each = local.effective_webhook_route_prefixes
          iterator = route
          content {
            path      = route.value
            path_type = "Prefix"
            backend {
              service {
                name = local.effective_webhook_service_name
                port { number = local.effective_service_port }
              }
            }
          }
        }

        dynamic "path" {
          for_each = local.effective_main_route_prefixes
          iterator = route
          content {
            path      = route.value
            path_type = "Prefix"
            backend {
              service {
                name = local.effective_main_service_name
                port { number = local.effective_service_port }
              }
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
        hosts       = [local.n8n_fqdn]
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
  count = var.create_ingress ? 1 : 0

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

# Same warning pattern for External Secrets: an update interval set while the
# master switch is off is silently ignored by the wiring above.

check "external_secrets_update_interval_requires_master_switch" {
  assert {
    condition     = var.n8n_external_secrets_enabled || var.n8n_external_secrets_update_interval == null
    error_message = "n8n_external_secrets_update_interval is set, but n8n_external_secrets_enabled is false, the update interval will be ignored and no N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL env var will be set on the n8n pods. Set n8n_external_secrets_enabled = true to apply it, or clear n8n_external_secrets_update_interval to silence this warning."
  }
}

# ── Application portability diagnostics ────────────────────────────────────
# Non-blocking warnings for input combinations that plan cleanly but silently
# do nothing useful, mirroring the OTEL/log-streaming/External-Secrets pattern
# above.

# N8N_EXECUTION_DATA_STORAGE_MODE only exists from n8n 2.27. On an older image
# the env var is simply ignored: pods come up healthy and execution data keeps
# going to PostgreSQL, entirely silently. Only a tag shaped like
# MAJOR.MINOR.<rest> is compared (covers "2.27.4" and "2.27.4-alpine");
# anything else, including null (the chart's floating `stable`) and
# pre-release/channel tags, is left alone rather than guessed at. Written as
# nested ternaries because Terraform does not short-circuit && / || (see
# AGENTS.md), so the numeric comparisons must sit on a branch that is only
# taken once the regex has confirmed they are numbers.
check "execution_data_s3_requires_n8n_2_27" {
  assert {
    condition = var.n8n_execution_data_storage_mode != "s3" ? true : (
      var.n8n_image_tag == null ? true : (
        can(regex("^[0-9]+\\.[0-9]+\\.", var.n8n_image_tag)) ? (
          tonumber(split(".", var.n8n_image_tag)[0]) > 2 ? true : (
            tonumber(split(".", var.n8n_image_tag)[0]) == 2 ? tonumber(split(".", var.n8n_image_tag)[1]) >= 27 : false
          )
        ) : true
      )
    )
    error_message = join("", [
      "n8n_execution_data_storage_mode = \"s3\" requires n8n >= 2.27, but n8n_image_tag is pinned to ",
      "\"${coalesce(var.n8n_image_tag, "null")}\". Older versions ignore N8N_EXECUTION_DATA_STORAGE_MODE ",
      "entirely: the pods start fine and execution data silently keeps going to PostgreSQL. Pin ",
      "n8n_image_tag to 2.27.0 or later, or set n8n_execution_data_storage_mode = \"database\".",
    ])
  }
}

# Image pull Secrets attached with nothing that needs them: both the chart's
# stock image and, with task runners on, its stock runner image are public and
# need no credentials, so the secrets are attached and never used. The cost is
# not zero: setting n8n_image_pull_secrets moves ownership of the
# ServiceAccount from the chart to the module (see
# local.n8n_manages_service_account).
check "image_pull_secrets_need_a_custom_image" {
  assert {
    condition     = length(var.n8n_image_pull_secrets) > 0 ? var.n8n_image_repository != null : true
    error_message = "n8n_image_pull_secrets is set but n8n_image_repository is null, so every image the pods pull comes from a public registry. Neither needs credentials, so the secrets are attached and never used. The cost is not zero: setting this input moves ownership of the ServiceAccount from the chart to the module. Clear it to hand the account back, or set n8n_image_repository to the private image these credentials are for."
  }
}

# A custom app image tagged with something that is not itself a published n8n
# version (e.g. "2.27.4-mypackages") needs n8n_task_runner_image_tag set,
# otherwise the chart derives the sidecar's tag from the app image's tag and
# every main/worker pod stays in ImagePullBackOff.
check "custom_image_tag_requires_task_runner_tag" {
  assert {
    condition = var.n8n_image_repository != null ? (
      var.n8n_task_runners_enabled ? (
        var.n8n_image_tag == null || var.n8n_task_runner_image_tag != null
      ) : true
    ) : true
    error_message = "A custom n8n image (n8n_image_repository + n8n_image_tag) is set with task runners enabled, but n8n_task_runner_image_tag is null. The chart tags the runner sidecar from the app image by default, so the sidecar resolves to <runner repository>:<n8n_image_tag> and every main and worker pod fails with ImagePullBackOff unless that exact tag exists upstream. Set n8n_task_runner_image_tag to the n8n version the custom image is built from. Ignore this warning if the custom image's tag is itself a published n8n version."
  }
}

# A task-runner image tag with task runners disabled plans cleanly but is
# never applied: the chart renders no runner sidecar at all in that case.
check "task_runner_image_tag_requires_task_runners" {
  assert {
    condition     = var.n8n_task_runner_image_tag != null ? var.n8n_task_runners_enabled : true
    error_message = "n8n_task_runner_image_tag is set, but n8n_task_runners_enabled is false, so no runner sidecar is deployed and the tag is ignored. Set n8n_task_runners_enabled = true to apply it, or clear the tag to silence this warning."
  }
}

check "task_runner_image_repository_requires_task_runners" {
  assert {
    condition     = var.n8n_task_runner_image_repository != null ? var.n8n_task_runners_enabled : true
    error_message = "n8n_task_runner_image_repository is set, but n8n_task_runners_enabled is false, so no runner sidecar is deployed and the repository is ignored. Set n8n_task_runners_enabled = true to apply it, or clear the repository to silence this warning."
  }
}

# Nothing in this module puts files at n8n_custom_extensions_path unless a
# custom image bakes them in.
check "custom_extensions_path_requires_a_custom_image" {
  assert {
    condition     = var.n8n_custom_extensions_path != null ? var.n8n_image_repository != null : true
    error_message = "n8n_custom_extensions_path is set, but n8n_image_repository is null, so the pods run the chart's stock image. n8n will scan an empty or missing directory and load no nodes, silently. Point n8n_image_repository at an image with the compiled nodes baked in at this path, or clear the path to silence this warning."
  }
}
