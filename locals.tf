# ── Locals ────────────────────────────────────────────────────────────────────
# Shared values derived from inputs: input aliases, the common tag set every
# taggable resource merges in, and the deterministic S3 bucket name.

locals {
  # Aliases for inputs so the rest of the module can reference them uniformly.
  # Naming scheme: <friendly_name_prefix>-n8n<-suffix>, e.g. <prefix>-n8n-pg.
  name_prefix = "${var.friendly_name_prefix}-n8n"
  n8n_fqdn    = var.n8n_fqdn

  # One effective webhook base URL (task 19.1): explicit n8n_webhook_url,
  # otherwise https://<n8n_fqdn>. Shared by both the legacy WEBHOOK_URL and
  # current N8N_WEBHOOK_URL environment names in n8n.tf's config.extraEnv, so
  # the two never drift apart.
  effective_webhook_url = coalesce(var.n8n_webhook_url, "https://${local.n8n_fqdn}")

  # (GCP labels live in local.gcp_labels, network.tf.)

  # ── n8n_extra_env collision guard ──────────────────────────────────────────
  # config.extraEnv is appended LAST in every n8n container's env list (see the
  # n8n Helm chart's deployment-*.yaml templates), and Kubernetes resolves
  # duplicate env names last-wins. So any name a caller passes via
  # var.n8n_extra_env overrides the value the module or chart set for it. These
  # two lists are the reserved surface the escape hatch must not touch:
  # connection, identity, storage, license, and topology vars whose override
  # would silently break or hijack the deployment.
  #
  # Exact names: set by the module in config.extraEnv / the n8n secret, plus the
  # chart-rendered identity/topology/storage/license vars not covered by a
  # prefix below. Keep in sync with the extraEnv block in n8n.tf and the chart
  # values the module sets (database/redis/s3/multiMain/license/secretRefs).
  n8n_managed_env_names = [
    # Set by the module in config.extraEnv or the n8n secret.
    "N8N_ENCRYPTION_KEY",
    "N8N_LOG_LEVEL",
    "N8N_LOG_OUTPUT",
    "N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS",
    "N8N_METRICS",
    "N8N_REINSTALL_MISSING_PACKAGES",
    "N8N_COMMUNITY_PACKAGES_PREVENT_LOADING",
    "WEBHOOK_URL",
    "N8N_WEBHOOK_URL",
    "N8N_TEMPLATES_ENABLED",
    "N8N_PERSONALIZATION_ENABLED",
    "N8N_OTEL_ENABLED",
    "N8N_OTEL_EXPORTER_OTLP_ENDPOINT",
    "N8N_OTEL_EXPORTER_OTLP_HEADERS",
    "N8N_OTEL_EXPORTER_SERVICE_NAME",
    "N8N_OTEL_TRACES_SAMPLE_RATE",
    "N8N_OTEL_TRACES_INCLUDE_NODE_SPANS",
    "N8N_OTEL_TRACES_INJECT_OUTBOUND",
    "N8N_OTEL_TRACES_PRODUCTION_ONLY",
    "N8N_LOG_STREAMING_MANAGED_BY_ENV",
    "N8N_LOG_STREAMING_DESTINATIONS",
    "N8N_DISABLED_MODULES",
    "N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL",
    "N8N_CUSTOM_EXTENSIONS",
    "N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN",
    "N8N_EXECUTION_DATA_STORAGE_MODE",
    "NODE_EXTRA_CA_CERTS",
    # Redis command-channel prefix (task 7.1), synchronized with the chart's
    # redis.prefix (Bull queue keys, set unconditionally as "" or the
    # supplied value in n8n.tf) via var.redis_key_prefix. Emitted only when
    # var.redis_key_prefix is non-null (see the extraEnv block in n8n.tf).
    "N8N_REDIS_KEY_PREFIX",
    # Community registry and security-related runtime controls (task 15),
    # emitted only when their respective input is non-null (see the
    # extraEnv block in n8n.tf).
    "N8N_COMMUNITY_PACKAGES_REGISTRY",
    "N8N_UNVERIFIED_PACKAGES_ENABLED",
    "N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES",
    "N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES",
    # Rendered by the chart from executions.data (n8n_executions_data_save_*
    # in variables.tf via local.n8n_executions_data). Reserved even though
    # the module already sets a value for each (rather than leaving them
    # unset when at their default), since config.extraEnv would otherwise
    # silently override the caller's chosen save policy.
    "EXECUTIONS_DATA_SAVE_ON_SUCCESS",
    "EXECUTIONS_DATA_SAVE_ON_ERROR",
    "EXECUTIONS_DATA_SAVE_ON_PROGRESS",
    "EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS",
    # Rendered by the chart from module values (identity, topology, storage,
    # license). DB_*, QUEUE_*, N8N_RUNNERS_*, N8N_EXTERNAL_STORAGE_S3_*,
    # N8N_MULTI_MAIN_*, and AWS_* are covered by n8n_managed_env_prefixes.
    "EXECUTIONS_MODE",
    "OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS",
    "N8N_DEFAULT_BINARY_DATA_MODE",
    "N8N_AVAILABLE_BINARY_DATA_MODES",
    "N8N_LICENSE_ACTIVATION_KEY",
    "N8N_HOST",
    "N8N_PORT",
    "N8N_PROTOCOL",
    "N8N_EDITOR_BASE_URL",
    "N8N_DISABLE_PRODUCTION_MAIN_PROCESS",
    "N8N_NATIVE_PYTHON_RUNNER",
    "TZ",
  ]

  # Whole env-var families the module/chart owns, matched by prefix so the guard
  # stays correct when the chart adds new members. This intentionally fails
  # closed: it also blocks DB_*/QUEUE_* *tuning* vars the module does not set
  # today (e.g. DB_LOGGING_ENABLED). If a caller has a genuine need for one, add
  # an exact-match carve-out rather than narrowing the prefix.
  n8n_managed_env_prefixes = [
    "DB_",
    "QUEUE_",
    "N8N_RUNNERS_",
    "N8N_EXTERNAL_STORAGE_S3_",
    "N8N_MULTI_MAIN_",
    "AWS_",
  ]

  # External Secrets (D7): the master switch maps to n8n's comma-separated
  # N8N_DISABLED_MODULES module-disable list. Only one module is disabled
  # today, but the list shape keeps this extensible without reshaping the env
  # var wiring in n8n.tf.
  n8n_disabled_modules = join(",", compact([
    var.n8n_external_secrets_enabled ? "" : "external-secrets",
  ]))

  # ── n8n Kubernetes ServiceAccount ownership ────────────────────────────────
  # The chart creating its own ServiceAccount is the arrangement we want, with
  # one exception: the pinned chart version renders imagePullSecrets nowhere,
  # not on the pod spec and not on the ServiceAccount, so a private registry
  # has no way in through chart values. Attaching the secrets to the account
  # the pods already run as is the remaining lever, and the chart supports it
  # (serviceAccount.create = false with an externally managed name).
  #
  # The module-managed account uses a different name than the chart's default
  # (var.n8n_kube_svc_account) so enabling n8n_image_pull_secrets on an
  # already-applied stack does not collide with the account Helm still owns;
  # the Workload Identity binding (workload_identity.tf) targets whichever name
  # is effective.
  n8n_manages_service_account = length(var.n8n_image_pull_secrets) > 0
  n8n_service_account_name    = local.n8n_manages_service_account ? "${var.n8n_kube_svc_account}-pull" : var.n8n_kube_svc_account
}

# ── Ownership-neutral effective coordinates ──────────────────────────────────
# n8n wiring, controller wiring, and outputs consume these locals instead of
# branching on ownership themselves, so every downstream file speaks one
# ownership-neutral contract regardless of whether a layer is module-managed
# or customer-managed. Resource-level `count` gating for each layer lands in
# its own task section (network.tf / gke.tf / memorystore.tf / gcs.tf); until
# then the "managed" branch below still points at the unconditional resource,
# and the "existing" branch is exercised only through its variable contract.

locals {
  # Network and Private Service Access. Shared VPC: the existing network can
  # live in a different host project than project_id.
  effective_network_project_id = coalesce(var.existing_network_project_id, var.project_id)

  effective_network_self_link = var.create_network ? google_compute_network.n8n[0].self_link : "projects/${local.effective_network_project_id}/global/networks/${var.existing_network_name}"
  effective_network_id        = var.create_network ? google_compute_network.n8n[0].id : local.effective_network_self_link

  effective_subnetwork_self_link = var.create_network ? google_compute_subnetwork.n8n[0].self_link : "projects/${local.effective_network_project_id}/regions/${var.gcp_region}/subnetworks/${var.existing_subnetwork_name}"

  effective_pods_range_name     = var.create_network ? "${local.name_prefix}-pods" : var.existing_pods_range_name
  effective_services_range_name = var.create_network ? "${local.name_prefix}-services" : var.existing_services_range_name

  # GKE cluster. The existing-cluster branch reads data.google_container_cluster.existing
  # (gke.tf), whose lifecycle postconditions enforce the observable
  # VPC-native/Workload Identity prerequisites before these locals resolve.
  effective_gke_cluster_name           = var.create_gke ? google_container_cluster.n8n[0].name : var.existing_gke_cluster_name
  effective_gke_cluster_endpoint       = var.create_gke ? google_container_cluster.n8n[0].endpoint : data.google_container_cluster.existing[0].endpoint
  effective_gke_cluster_ca_certificate = var.create_gke ? try(google_container_cluster.n8n[0].master_auth[0].cluster_ca_certificate, null) : try(data.google_container_cluster.existing[0].master_auth[0].cluster_ca_certificate, null)
  # existing_gke_workload_identity_pool is only consulted on the
  # existing-cluster branch; a managed cluster always uses this project's own
  # pool, so a stray reference input cannot silently rewrite the Workload
  # Identity binding (checks.tf's gke_references_ignored_when_managed warns
  # about the ignored input).
  effective_gke_workload_identity_pool = var.create_gke ? "${var.project_id}.svc.id.goog" : coalesce(
    var.existing_gke_workload_identity_pool,
    try(data.google_container_cluster.existing[0].workload_identity_config[0].workload_pool, null),
    "${var.project_id}.svc.id.goog"
  )

  # PostgreSQL. The existing-database branch supplies exactly one password
  # source (n8n_database_password_secret_ref.name is null on the direct-value
  # path); manage_db_secret decides whether n8n.tf's kubernetes_secret.n8n_db
  # is created at all, or whether n8n reads the caller's existing Secret
  # directly (D7). effective_postgres_kms_key_id lives in kms.tf next to the
  # key resources it derives from.
  effective_postgres_host = var.create_postgres_instance ? google_sql_database_instance.n8n[0].private_ip_address : var.n8n_database_host

  manage_db_secret = var.create_postgres_instance || var.n8n_database_password_secret_ref == null

  effective_db_password_secret_name = local.manage_db_secret ? kubernetes_secret.n8n_db[0].metadata[0].name : var.n8n_database_password_secret_ref.name
  effective_db_password_secret_key  = local.manage_db_secret ? "password" : var.n8n_database_password_secret_ref.key

  # Namespace: the name is the same whether the module creates it or not.
  effective_namespace = var.n8n_kube_namespace

  # Core Secret (D7): mirrors the PostgreSQL/Redis password-source pattern.
  # manage_core_secret decides whether n8n.tf's kubernetes_secret.n8n (and the
  # encryption key it wraps) is created at all, or whether n8n reads the
  # caller's existing core Secret directly via secretRefs.existingSecret.
  manage_core_secret         = var.existing_n8n_core_secret_name == null
  effective_core_secret_name = local.manage_core_secret ? kubernetes_secret.n8n[0].metadata[0].name : var.existing_n8n_core_secret_name

  # effective_encryption_key: the direct var.n8n_encryption_key when supplied,
  # else the generated random_id (n8n.tf only creates that resource when
  # manage_core_secret is true and no direct key was supplied), else null for
  # an unread external core Secret.
  effective_encryption_key = local.manage_core_secret ? coalesce(var.n8n_encryption_key, try(random_id.n8n_encryption_key[0].hex, null)) : null

  # License (D7 continued): a direct n8n_license_key wraps into a dedicated
  # module-managed Secret (n8n.tf's kubernetes_secret.n8n_license) instead of
  # rendering the literal activation key into Helm values; a caller-supplied
  # n8n_license_key_secret_ref is used as-is and creates no managed Secret.
  # The two sources remain mutually exclusive (variables.tf's validation), so
  # exactly one of these branches is ever active.
  manage_license_secret = var.n8n_license_key != null

  effective_license_secret_name = local.manage_license_secret ? kubernetes_secret.n8n_license[0].metadata[0].name : var.n8n_license_key_secret_ref.name
  effective_license_secret_key  = local.manage_license_secret ? "license-key" : var.n8n_license_key_secret_ref.key

  # Redis. ACL usernames are meaningful only on the external path; managed
  # Memorystore has no concept of one. manage_redis_secret/
  # effective_redis_password_secret_* mirror PostgreSQL's D7 password-source
  # pattern: managed AUTH wraps the generated auth_string (keda.tf's
  # kubernetes_secret.redis_auth), external Redis accepts a direct value
  # (wrapped in n8n.tf's kubernetes_secret.n8n_redis) or an existing Secret
  # reference used as-is. manage_redis_tls_ca identifies the module-managed
  # Memorystore TLS path whose Google CA must be trusted explicitly by n8n and
  # KEDA. manage_redis_trigger_auth/manage_redis_username_secret decide whether
  # KEDA gets a TriggerAuthentication and username Secret.
  effective_redis_host        = var.create_redis_instance ? google_redis_instance.n8n[0].host : var.redis_host
  effective_redis_port        = var.create_redis_instance ? google_redis_instance.n8n[0].port : var.redis_port
  effective_redis_tls_enabled = var.create_redis_instance ? var.redis_transit_encryption_enabled : var.redis_tls_enabled
  effective_redis_username    = var.create_redis_instance ? null : var.redis_username

  manage_redis_secret = !var.create_redis_instance && var.redis_password != null

  effective_redis_password_secret_name = var.create_redis_instance ? (
    var.redis_auth_enabled ? kubernetes_secret.redis_auth[0].metadata[0].name : null
    ) : (
    var.redis_password_secret_ref != null ? var.redis_password_secret_ref.name : (
      local.manage_redis_secret ? kubernetes_secret.n8n_redis[0].metadata[0].name : null
    )
  )
  effective_redis_password_secret_key = var.create_redis_instance ? (
    var.redis_auth_enabled ? "password" : null
    ) : (
    var.redis_password_secret_ref != null ? var.redis_password_secret_ref.key : (
      local.manage_redis_secret ? "password" : null
    )
  )

  manage_redis_tls_ca          = var.create_redis_instance && var.redis_transit_encryption_enabled
  manage_redis_trigger_auth    = local.effective_redis_password_secret_name != null || local.manage_redis_tls_ca
  manage_redis_username_secret = local.effective_redis_username != null
  effective_redis_key_prefix   = coalesce(var.redis_key_prefix, "bull")

  # Bull queue key names KEDA (n8n.tf) and the opt-in Redis exporter
  # (observability.tf, section 16) both watch, sharing the same prefix as
  # n8n's own Bull queue and command-channel keys (redis.prefix /
  # N8N_REDIS_KEY_PREFIX below) so all three consumers agree on which lists
  # hold queued and in-flight jobs.
  effective_redis_queue_keys = {
    waiting = "${local.effective_redis_key_prefix}:jobs:wait"
    active  = "${local.effective_redis_key_prefix}:jobs:active"
  }

  # Queue lock/stall tuning (redis.worker in the chart): built as one nested
  # map, not three independent top-level merge() calls in n8n.tf, so setting
  # only one of the three values cannot shallow-merge over and discard the
  # chart's own defaults for the other two (each key is present in this map
  # only when its corresponding variable is non-null; Helm still supplies its
  # own default for any key absent here).
  n8n_queue_worker_chart_overrides = merge(
    var.n8n_queue_worker_lock_duration != null ? { lockDuration = var.n8n_queue_worker_lock_duration } : {},
    var.n8n_queue_worker_lock_renew_time != null ? { lockRenewTime = var.n8n_queue_worker_lock_renew_time } : {},
    var.n8n_queue_worker_stalled_interval != null ? { stalledInterval = var.n8n_queue_worker_stalled_interval } : {},
  )

  # GCS bucket. HMAC identity/key ownership (gcs.tf) is independent of bucket
  # ownership and already exposes its own locals (hmac_sa_email, etc.).
  # effective_gcs_kms_key_id lives in kms.tf next to the key resources it
  # derives from.
  effective_gcs_bucket_name = var.create_gcs_bucket ? google_storage_bucket.n8n[0].name : var.existing_gcs_bucket_name

  # Stable service and route contract exposed for customer-managed ingress.
  # These are the n8n Helm chart's fixed service names/port for the release
  # name "n8n" (see helm_release.n8n in n8n.tf); the full route/backend fix-up
  # (webhook-waiting, form, form-waiting, mcp) lands in the ingress ownership
  # task section.
  effective_main_service_name    = "n8n-main"
  effective_webhook_service_name = "n8n-webhook-processor"
  effective_service_port         = 5678
  effective_main_route_prefixes  = ["/"]
  effective_webhook_route_prefixes = [
    "/webhook",
    "/webhook-waiting",
    "/form",
    "/form-waiting",
    "/mcp",
  ]

  # Additional ingress hosts: canonical hostname first, then every configured
  # n8n_additional_domains entry, normalized to lowercase (the variable's own
  # validation already rejects duplicates and a repeat of n8n_fqdn
  # case-insensitively). n8n_fqdn itself is passed through unchanged,
  # matching every other consumer of local.n8n_fqdn. Consumed by the managed
  # Ingress rules/TLS, Cloud DNS records, ManagedCertificate domains, and
  # self-signed cert SANs (n8n.tf/dns.tf/crds.tf), and exposed unconditionally
  # via the n8n_ingress_hosts output so a customer-managed ingress can route
  # the same effective list.
  n8n_effective_additional_domains = [for d in var.n8n_additional_domains : lower(d)]
  n8n_effective_ingress_hosts      = concat([local.n8n_fqdn], local.n8n_effective_additional_domains)
}

# ── n8n Helm chart value fragments ───────────────────────────────────────────
# Input-derived fragments of helm_release.n8n's values (n8n.tf), factored out
# so this change's chart-rendering script (tests/scripts/check-n8n-chart.sh)
# and later sections (topology-aware main behavior, execution-save controls)
# consume the exact same computed values the release does, rather than a
# second copy of the same formula. Keep this to fragments this change actually
# touches; do not pre-extract chart values unrelated to this change's scope.

locals {
  # Fixed replica counts fall back to n8n_*_fixed_replicas when the caller owns
  # that pod's scaling (n8n_main_hpa_enabled / n8n_webhook_hpa_enabled /
  # n8n_worker_keda_enabled = false); otherwise they seed the initial replica
  # count at the scaler's own minimum, which the HPA/KEDA ScaledObject
  # immediately takes over (D9). n8n_effective_main_replica_count also drives
  # single-main/multi-main topology selection below.
  n8n_effective_main_replica_count    = var.n8n_main_hpa_enabled ? var.n8n_main_hpa_min_replicas : var.n8n_main_fixed_replicas
  n8n_effective_worker_replica_count  = var.n8n_worker_keda_enabled ? var.n8n_worker_keda_min_replicas : var.n8n_worker_fixed_replicas
  n8n_effective_webhook_replica_count = var.n8n_webhook_hpa_enabled ? var.n8n_webhook_hpa_min_replicas : var.n8n_webhook_fixed_replicas

  # ── Single-main / multi-main topology (main-topology capability) ──────────
  # This count-based flag owns rollout, PDB, and scaling safeguards, not the
  # election override. Staging election at one replica must retain all three.
  n8n_single_main = local.n8n_effective_main_replica_count == 1

  # Enable election before increasing replicas in a separate apply. Null
  # preserves the existing count-derived default. False above one is rejected
  # by the input validation; never scale an election-disabled old revision.
  n8n_main_leader_election_enabled = var.n8n_main_leader_election_enabled == null ? !local.n8n_single_main : var.n8n_main_leader_election_enabled

  # Chart 1.10.1 requires >=2 replicas for multiMain.enabled. Stage runtime
  # election through the module-owned environment instead, retaining the
  # chart's one-replica layout and validation. config.extraEnv reaches all
  # n8n roles, so staging also rolls workers and webhook processors.
  n8n_main_election_staging_env = local.n8n_single_main && local.n8n_main_leader_election_enabled ? [
    { name = "N8N_MULTI_MAIN_SETUP_ENABLED", value = "true" },
  ] : []

  # A module-owned main HPA never scales a single-main deployment past its
  # licensed ceiling of one main: single-main clamps the effective maximum to
  # one regardless of the configured n8n_main_hpa_max_replicas, so raising
  # that bound later (without changing the minimum) cannot silently grow past
  # one main pod. capacity.tf's estimate consumes this same effective ceiling.
  n8n_effective_main_hpa_max_replicas = local.n8n_single_main ? 1 : var.n8n_main_hpa_max_replicas

  # At a fixed count of one, Recreate stops the old main before starting its
  # replacement, including when staging election. It does not order a replica
  # increase against a template change; conversion needs separate applies.
  # {} (the chart's own default) leaves multi-main's existing rollout
  # behavior untouched; this does not change worker or webhook strategy.
  n8n_main_strategy = local.n8n_single_main ? { type = "Recreate" } : {}

  # A single main's PDB must allow its own (only) replica to be evicted during
  # a voluntary disruption (e.g. node drain); minAvailable=1 would block that
  # eviction entirely. Multi-main keeps the existing minAvailable=1 floor.
  n8n_main_pdb_min_available = local.n8n_single_main ? 0 : 1

  # Execution-save policy: the single place both the Helm release
  # (helm_release.n8n.values.executions.data in n8n.tf) and the
  # chart-rendering script read the effective policy from.
  n8n_executions_data = {
    saveOnError          = var.n8n_executions_data_save_on_error
    saveOnSuccess        = var.n8n_executions_data_save_on_success
    saveOnProgress       = var.n8n_executions_data_save_on_progress
    saveManualExecutions = var.n8n_executions_data_save_manual_executions
  }

  # ── Caller-managed volumes (task 10) ───────────────────────────────────────
  # Transforms var.n8n_extra_volumes/n8n_extra_volume_mounts into the chart's
  # raw Kubernetes extraVolumes/extraVolumeMounts shape (toYaml-passthrough,
  # see templates/deployment-*.yaml), converting each octal default_mode
  # string (e.g. "0440") to the decimal representation Kubernetes' defaultMode
  # field expects (288). n8n.tf concats these after the module's own Redis CA
  # volume/mount so caller mounts coexist with it rather than replacing it.
  n8n_caller_extra_volumes = [
    for v in var.n8n_extra_volumes : merge(
      { name = v.name },
      v.config_map != null ? {
        configMap = merge(
          { name = v.config_map.name },
          v.config_map.items != null ? {
            items = [for i in v.config_map.items : { key = i.key, path = i.path }]
          } : {},
          v.config_map.default_mode != null ? { defaultMode = parseint(v.config_map.default_mode, 8) } : {},
        )
      } : {},
      v.secret != null ? {
        secret = merge(
          { secretName = v.secret.name },
          v.secret.items != null ? {
            items = [for i in v.secret.items : { key = i.key, path = i.path }]
          } : {},
          v.secret.default_mode != null ? { defaultMode = parseint(v.secret.default_mode, 8) } : {},
        )
      } : {},
      v.persistent_volume_claim != null ? {
        persistentVolumeClaim = { claimName = v.persistent_volume_claim.claim_name }
      } : {},
    )
  ]

  n8n_caller_extra_volume_mounts = [
    for m in var.n8n_extra_volume_mounts : merge(
      { name = m.name, mountPath = m.mount_path, readOnly = m.read_only },
      m.sub_path != null ? { subPath = m.sub_path } : {},
    )
  ]

  # ── Credential-overwrite Secret reference (task 11) ────────────────────────
  # Mirrors the managed Redis CA volume's shape: a single-key Secret volume,
  # mounted read-only as one file, added to helm_release.n8n's
  # extraVolumes/extraVolumeMounts (n8n.tf) ahead of any caller-declared
  # n8n_extra_volumes/n8n_extra_volume_mounts. The module never reads
  # var.n8n_credentials_overwrite_secret_ref's Secret value, only its
  # name/key reference.
  n8n_credentials_overwrite_enabled = var.n8n_credentials_overwrite_secret_ref != null

  n8n_credentials_overwrite_volume = local.n8n_credentials_overwrite_enabled ? {
    name = "credentials-overwrite"
    secret = {
      secretName = var.n8n_credentials_overwrite_secret_ref.name
      items = [{
        key  = var.n8n_credentials_overwrite_secret_ref.key
        path = "overwrites.json"
      }]
    }
  } : null

  n8n_credentials_overwrite_mount = local.n8n_credentials_overwrite_enabled ? {
    name      = "credentials-overwrite"
    mountPath = "/etc/n8n/credentials-overwrite/overwrites.json"
    subPath   = "overwrites.json"
    readOnly  = true
  } : null

  # ── Pod DNS (task 13) ─────────────────────────────────────────
  # var.n8n_dns_config with unset keys removed.
  #
  # Necessary because the variable's optional() attributes materialize as null
  # rather than being absent, and the chart renders dnsConfig with a bare
  # `{{- toYaml . }}`. Passing the variable through directly would emit
  # `nameservers: null` / `searches: null` into the pod spec, which the API
  # server rejects (it expects a list, not null) with an error that names the
  # pod rather than the Helm value, so it is slow to trace back to here.
  #
  # `options` is rebuilt element-by-element for the same reason: an option with
  # no value is legal DNS (`options edns0` carries no value) and must render as
  # `{name: edns0}`, not `{name: edns0, value: null}`.
  n8n_dns_config_options = var.n8n_dns_config == null ? [] : [
    for o in coalesce(var.n8n_dns_config.options, []) :
    o.value == null ? { name = o.name } : { name = o.name, value = o.value }
  ]

  n8n_dns_config_stripped = var.n8n_dns_config == null ? {} : {
    for k, v in {
      nameservers = var.n8n_dns_config.nameservers
      searches    = var.n8n_dns_config.searches
      options     = length(local.n8n_dns_config_options) == 0 ? null : local.n8n_dns_config_options
    } : k => v if v != null
  }

  # Collapsed to null when nothing survives the stripping, so a caller passing
  # `n8n_dns_config = {}` (or all-null attributes) omits the dnsConfig key from
  # the Helm values entirely rather than rendering `dnsConfig: {}`, keeping the
  # variable's "null omits the block entirely" promise true for every
  # equivalent-to-unset shape.
  n8n_dns_config = length(local.n8n_dns_config_stripped) == 0 ? null : local.n8n_dns_config_stripped
}
