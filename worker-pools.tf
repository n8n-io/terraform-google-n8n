# ── Worker pools ──────────────────────────────────────────────────────────────
# EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE. This tracks two upstream
# features that are themselves alpha: n8n's own worker pools, and the chart
# support for them (queueMode.workerGroups, n8n-io/n8n-hosting#189), merged to
# the chart's preview/worker-pools branch but not released to a numbered chart
# version. This file's shape, defaults and guards may change to match either
# upstream, without the usual deprecation path. Ported from
# terraform-aws-n8n's worker-pools.tf, kept as close to 1:1 as this module's
# own Redis/KEDA wiring (locals.tf, n8n.tf) allows.
#
# Maps var.n8n_worker_pools onto the chart's queueMode.workerGroups, which
# renders one worker Deployment per pool plus a KEDA ScaledObject watching that
# pool's own `jobs-<name>` queue.
#
# The module keeps its own input shape rather than passing the chart's through
# verbatim: pool names are validated at plan time (see variables.tf), the
# per-pool sizing knobs fall back to the module-wide worker defaults instead of
# the chart's, and a pool here is always a pool, whereas a chart worker group
# without a poolName is just an extra unlabelled worker deployment.
#
# Requires a chart version whose queueMode.workerGroups exists. n8n-hosting's
# own release-please cuts numbered releases from main independently of the
# preview/worker-pools branch that carries the feature, so no numbered
# version can be trusted as a floor: one that predates the feature ships
# under the same versioning scheme as one that would carry it, and a
# release cut from main can never prove the feature is present.
# Until n8n-io/n8n-hosting#189 merges to main and a numbered release
# actually carries it, only a prerelease build passes automatically, or a
# numbered build the caller attests with n8n_worker_pools_chart_verified
# (see that variable and locals.n8n_chart_renders_worker_pools below).
# n8n-io/n8n-hosting#191 registered a `Preview chart` GitHub Action on that
# repo's main branch that packages preview/worker-pools and publishes an
# official prerelease build to oci://ghcr.io/n8n-io/n8n-helm-chart (this
# module's default n8n_chart_repository) once someone with write access to
# that repo dispatches it against preview/worker-pools. See n8n_chart_version
# and the two checks at the bottom of this file, and
# examples/worker-pools/README.md for the exact command and a
# private-mirror fallback.

locals {
  # First n8n release that reads N8N_WORKER_POOLS_ENABLED and
  # N8N_WORKER_POOL_NAME (packages/@n8n/config, scaling-mode.config.ts, first
  # tagged in n8n@2.39.0). Older images accept both variables and ignore them:
  # mains never route to a pool and pool workers consume the default queue.
  n8n_worker_pools_min_n8n_minor = 39

  # No numbered n8n-hosting release carries queueMode.workerGroups: the
  # feature is merged only to the preview/worker-pools branch, and main's own
  # release-please cuts ship independently of it. There is no real floor to
  # compare against yet, so a numbered version only passes if the caller
  # explicitly attests it with n8n_worker_pools_chart_verified -- for example
  # a private mirror serving a numbered build of the feature branch. A
  # prerelease passes automatically, taken at the caller's word via the
  # SemVer 2 "-prerelease" separator specifically, with no extra input
  # needed. n8n_chart_version's own validation also allows an optional
  # "+buildmetadata" suffix with no hyphen (e.g. "1.11.0+build.5"); Helm
  # ignores build metadata when resolving a chart from an HTTPS/OCI
  # repository, so that string can resolve to plain "1.11.0" -- the exact
  # silent no-render case this guard exists to stop. Checking for the hyphen
  # directly, rather than "fails a strict X.Y.Z match", is what keeps a
  # build-metadata-only version from falling through as if it were a
  # prerelease. Replace this whole local with a real floor and a numeric
  # compare once n8n-io/n8n-hosting#189 merges to main and a numbered
  # release carries the feature; n8n_worker_pools_chart_verified can retire
  # at the same time.
  n8n_chart_renders_worker_pools = (
    can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-", var.n8n_chart_version)) ||
    var.n8n_worker_pools_chart_verified
  )

  # Extra KEDA Redis trigger metadata for a pool's ScaledObject. The chart
  # builds a pool's ScaledObject itself from queueMode.workerGroups[].keda,
  # and (unverified against the unreleased chart) that block is assumed to
  # accept triggerMetadata the same way terraform-aws-n8n's does, with no
  # equivalent of the authenticationRef the default worker's triggers use
  # (n8n.tf). So, unlike the default worker, AUTH reaches a pool's scaler as
  # metadata: passwordFromEnv names an environment variable KEDA resolves
  # against the pool's own worker container (QUEUE_BULL_REDIS_PASSWORD, set
  # by the chart's redis.passwordSecret value the same as every other
  # worker), so the token never appears in the ScaledObject manifest.
  #
  # enableTLS follows the default worker's rule exactly (always rendered as
  # "true"/"false", omitted only on the managed-CA path) so the two trigger
  # sets agree by construction; tests/scripts/verify-worker-pools.sh
  # compares them.
  #
  # Known gap versus the default worker: local.manage_redis_tls_ca (a
  # module-managed Memorystore instance with redis_transit_encryption_enabled
  # = true) trusts Memorystore's private CA through a TriggerAuthentication's
  # `ca` field, which this metadata-only path has no equivalent for, and the
  # omitted enableTLS on that path leaves the pool's scaler speaking
  # plaintext to a TLS-only endpoint (READY=False, `i/o timeout` in the KEDA
  # operator log). check.worker_pools_with_managed_redis_tls_ca below warns
  # about the combination at plan time.
  n8n_worker_pool_keda_metadata = merge(
    local.manage_redis_tls_ca ? {} : { enableTLS = tostring(local.effective_redis_tls_enabled) },
    local.effective_redis_password_secret_name != null ? { passwordFromEnv = "QUEUE_BULL_REDIS_PASSWORD" } : {},
    local.effective_redis_username != null ? { username = local.effective_redis_username } : {},
  )

  n8n_worker_groups = [
    for p in var.n8n_worker_pools : {
      # One group per pool, and the group is the pool: the chart allows a group
      # with no poolName (extra workers on the default queue), but this module
      # has n8n_worker_keda_{min,max}_replicas for sizing the default workers
      # and does not need a second way to do it.
      name     = p.name
      poolName = p.name

      concurrency = coalesce(p.concurrency, var.n8n_worker_concurrency)
      extraEnv    = p.extra_env

      resources = {
        requests = {
          cpu    = coalesce(p.cpu_request, var.n8n_worker_cpu_request)
          memory = coalesce(p.memory_request, var.n8n_worker_memory_request)
        }
        limits = {
          cpu    = coalesce(p.cpu_limit, var.n8n_worker_cpu_limit)
          memory = coalesce(p.memory_limit, var.n8n_worker_memory_limit)
        }
      }

      keda = {
        minReplicaCount = p.min_replicas
        maxReplicaCount = p.max_replicas
        # Same threshold the module gives the default worker's scaler, so a
        # pool's queue depth is read on the same scale as the default queue's.
        jobsPerReplica  = var.n8n_worker_keda_jobs_per_replica
        triggerMetadata = local.n8n_worker_pool_keda_metadata
      }
    }
  ]
}

# ── Guards ───────────────────────────────────────────────────────────────────
# Both of these exist because the failure they catch is silent in every other
# place it could be caught. A chart that predates queueMode.workerGroups has no
# additionalProperties: false on queueMode, so Helm accepts the key, renders
# nothing for it, and the release succeeds: N8N_WORKER_POOLS_ENABLED lands on
# every pod, no pool Deployment or ScaledObject exists, and every project
# pinned to a pool quietly runs on the default queue. Mocked plan-time tests
# cannot see any of that, and neither can a real plan; only counting the
# rendered Deployments after apply can (tests/scripts/verify-worker-pools.sh).
#
# The chart pairing is a hard stop, enforced as a precondition on
# helm_release.n8n (n8n.tf) because it is a property of that resource and
# because letting the apply proceed past a warning is exactly the silent
# outcome described above. A prerelease version is exempt automatically,
# which is how the official preview build (see the top of this file and
# examples/worker-pools/README.md) is installed while no release carries
# the feature; a numbered version passes only if the caller sets
# n8n_worker_pools_chart_verified, for a private mirror serving a numbered
# build it has already verified. The image pairing stays a warning, not a hard
# stop: n8n_image_tag is usually null (the chart's floating `stable`), which
# the check cannot see, so it cannot be relied on to catch every case. Unlike
# the chart pairing, an old image does not fail loudly -- it silently accepts
# and ignores N8N_WORKER_POOLS_ENABLED and N8N_WORKER_POOL_NAME, so the pods
# come up healthy with the feature doing nothing (measured on AWS; this is
# what the check's own error_message below describes, and what
# tests/scripts/verify-worker-pools.sh exists to catch after apply). A
# missing feat:workerPools licence entitlement is the one pool-related
# failure that *is* loud (the pooled workers exit 1), but that is a separate
# concern from the image tag and Terraform cannot see it at plan either.

locals {
  n8n_worker_pools_chart_error = join("", [
    "n8n_worker_pools declares ${length(var.n8n_worker_pools)} pool(s) but n8n_chart_version = \"${var.n8n_chart_version}\" ",
    "is a numbered release that n8n_worker_pools_chart_verified does not attest, and no numbered ",
    "n8n-hosting release carries queueMode.workerGroups yet: the feature (n8n-io/n8n-hosting#189) is ",
    "merged only to the chart's preview/worker-pools branch. That chart accepts the key and renders ",
    "nothing for it, so the release would apply cleanly with N8N_WORKER_POOLS_ENABLED switched on and no ",
    "pool Deployment or ScaledObject behind it, and every project pinned to a pool would run on the ",
    "default queue. Pin n8n_chart_version to a prerelease build that carries the feature (a version with ",
    "a hyphen is taken at your word, e.g. an official preview build such as ",
    "1.11.0-preview.workerpools.1 published to oci://ghcr.io/n8n-io/n8n-helm-chart via n8n-io/n8n-hosting's ",
    "Preview chart GitHub Action; see examples/worker-pools/README.md), set ",
    "n8n_worker_pools_chart_verified = true if this numbered version is a private mirror you have already ",
    "confirmed renders queueMode.workerGroups, or remove the pools.",
  ])
}

check "worker_pools_require_n8n_2_39" {
  assert {
    condition = length(var.n8n_worker_pools) > 0 && var.n8n_image_tag != null ? (
      can(regex("^[0-9]+\\.[0-9]+(\\.|$)", var.n8n_image_tag)) ? (
        tonumber(split(".", var.n8n_image_tag)[0]) > 2 ? true : (
          tonumber(split(".", var.n8n_image_tag)[0]) == 2
          ? tonumber(split(".", var.n8n_image_tag)[1]) >= local.n8n_worker_pools_min_n8n_minor
          : false
        )
      ) : true
    ) : true
    error_message = join("", [
      "n8n_worker_pools is set but n8n_image_tag is pinned to \"${coalesce(var.n8n_image_tag, "null")}\", ",
      "which predates worker pools (n8n >= 2.${local.n8n_worker_pools_min_n8n_minor}). Older images accept ",
      "N8N_WORKER_POOLS_ENABLED and N8N_WORKER_POOL_NAME and ignore both: mains never route to a pool and ",
      "pool workers consume the default queue, so the pods come up healthy and the feature does nothing. ",
      "Pin n8n_image_tag to 2.${local.n8n_worker_pools_min_n8n_minor}.0 or later. Leaving it null selects ",
      "the chart's floating `stable` tag, which this check cannot see; confirm that tag is new enough ",
      "before relying on it.",
    ])
  }
}

# Google-specific, no AWS counterpart (ElastiCache needs no custom CA trust).
# See the comment on local.n8n_worker_pool_keda_metadata: a pool's scaler has
# no route to Memorystore's private CA, so this combination applies cleanly
# and then fails silently (pool ScaledObjects READY=False, default workers
# healthy). A warning, not a hard stop, because a caller may have made the CA
# trusted out of band or accepted the pool sitting at min_replicas.
check "worker_pools_with_managed_redis_tls_ca" {
  assert {
    condition     = length(var.n8n_worker_pools) > 0 ? !local.manage_redis_tls_ca : true
    error_message = "n8n_worker_pools is set alongside a module-managed Memorystore instance with redis_transit_encryption_enabled = true. A pool's KEDA trigger metadata has no route for Memorystore's private CA (the default worker trusts it through the n8n-redis-auth TriggerAuthentication, which the chart's queueMode.workerGroups[].keda block has no equivalent of), so each pool's ScaledObject can fail to reach Redis and sit at min_replicas while the default workers stay healthy. Verify with tests/scripts/verify-worker-pools.sh before relying on this combination."
  }
}
