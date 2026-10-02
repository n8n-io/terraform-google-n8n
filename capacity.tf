# ── Managed GKE capacity guardrail (D11, capacity-guardrails) ────────────────
# Non-blocking, plan-time feedback for module-managed GKE only: estimates
# regional node-pool allocatable CPU/memory and compares it with the maximum
# n8n pod requests the caller's replica ceilings could ever schedule. Existing
# (customer-managed) GKE is skipped entirely (12.2): node pools can be
# heterogeneous and external autoscaling policy lives outside module state, so
# there is nothing safe to estimate.
#
# The estimate itself is approximate by design (documented in the `check`
# error messages below) and only ever emits a warning, never a plan failure.

# Zones available to a regional GKE cluster in gcp_region. The module sets no
# node_locations, and GKE replicates a regional node pool across three zones
# of the region by default (not every zone), so the zone count used for the
# estimate is capped at 3 below; in a four-zone region such as us-central1 the
# uncapped count would overstate capacity by a third.
data "google_compute_zones" "gke" {
  count = var.create_gke ? 1 : 0

  project = var.project_id
  region  = var.gcp_region
  status  = "UP"
}

# CPU/memory shape of the configured node machine type, read from one zone in
# the region (machine type availability is uniform across a region's zones in
# practice; the provider only exposes this as a zone-filtered list, not a
# single-machine-type lookup, hence the name = ... filter and [0] index below).
data "google_compute_machine_types" "gke" {
  count = var.create_gke ? 1 : 0

  project = var.project_id
  zone    = try(element(data.google_compute_zones.gke[0].names, 0), "${var.gcp_region}-a")
  filter  = "name = \"${var.gke_node_type}\""
}

locals {
  capacity_zone_count = var.create_gke ? min(3, length(data.google_compute_zones.gke[0].names)) : 0

  capacity_machine_cpu_cores  = var.create_gke ? try(data.google_compute_machine_types.gke[0].machine_types[0].guest_cpus, 0) : 0
  capacity_machine_memory_mib = var.create_gke ? try(data.google_compute_machine_types.gke[0].machine_types[0].memory_mb, 0) : 0

  # GKE reserves CPU and memory per node for the kubelet, container runtime,
  # and OS, on top of a fixed ~100MiB hard-eviction memory threshold. Tiers
  # below follow GKE's documented node-allocatable formula:
  # https://cloud.google.com/kubernetes-engine/docs/concepts/plan-node-sizes#node_allocatable_resources
  # This is a documented approximation, not a live read of the node pool's
  # actual allocatable capacity (which GKE does not expose as a plan-time
  # attribute).
  capacity_reserved_cpu_millicores = (
    min(local.capacity_machine_cpu_cores, 1) * 1000 * 0.06 +
    max(min(local.capacity_machine_cpu_cores, 2) - 1, 0) * 1000 * 0.01 +
    max(min(local.capacity_machine_cpu_cores, 4) - 2, 0) * 1000 * 0.005 +
    max(local.capacity_machine_cpu_cores - 4, 0) * 1000 * 0.0025
  )

  capacity_reserved_memory_mib = local.capacity_machine_memory_mib <= 0 ? 0 : (
    local.capacity_machine_memory_mib < 1024 ? 255 : (
      min(local.capacity_machine_memory_mib, 4096) * 0.25 +
      max(min(local.capacity_machine_memory_mib, 8192) - 4096, 0) * 0.20 +
      max(min(local.capacity_machine_memory_mib, 16384) - 8192, 0) * 0.10 +
      max(min(local.capacity_machine_memory_mib, 131072) - 16384, 0) * 0.06 +
      max(local.capacity_machine_memory_mib - 131072, 0) * 0.02
    ) + 100
  )

  capacity_allocatable_cpu_millicores_per_node = max(local.capacity_machine_cpu_cores * 1000 - local.capacity_reserved_cpu_millicores, 0)
  capacity_allocatable_memory_mib_per_node     = max(local.capacity_machine_memory_mib - local.capacity_reserved_memory_mib, 0)

  # gke_node_max_per_zone is a per-zone autoscaling ceiling (gke.tf); a
  # regional node pool's overall ceiling is that value times the zone count.
  capacity_total_nodes = var.gke_node_max_per_zone * local.capacity_zone_count

  capacity_total_allocatable_cpu_millicores = local.capacity_allocatable_cpu_millicores_per_node * local.capacity_total_nodes
  capacity_total_allocatable_memory_mib     = local.capacity_allocatable_memory_mib_per_node * local.capacity_total_nodes

  # Parses each Kubernetes CPU/memory quantity string this module's resource-
  # request variables accept into millicores / MiB so they can be compared
  # against the estimate above. Supports "m"-suffixed and bare-core CPU, and
  # Ki/Mi/Gi-suffixed (or bare byte) memory, matching every value this
  # module's variables actually accept (see the variable descriptions in
  # variables.tf).
  capacity_cpu_millicores_by_role = { for role, qty in {
    main        = var.n8n_main_cpu_request
    worker      = var.n8n_worker_cpu_request
    webhook     = var.n8n_webhook_cpu_request
    task_runner = var.n8n_task_runner_cpu_request
    } : role => (
    endswith(qty, "m") ? tonumber(trimsuffix(qty, "m")) : tonumber(qty) * 1000
    )
  }

  capacity_memory_mib_by_role = { for role, qty in {
    main        = var.n8n_main_memory_request
    worker      = var.n8n_worker_memory_request
    webhook     = var.n8n_webhook_memory_request
    task_runner = var.n8n_task_runner_memory_request
    } : role => (
    endswith(qty, "Gi") ? tonumber(trimsuffix(qty, "Gi")) * 1024 :
    endswith(qty, "Mi") ? tonumber(trimsuffix(qty, "Mi")) :
    endswith(qty, "Ki") ? tonumber(trimsuffix(qty, "Ki")) / 1024 :
    tonumber(qty) / 1024 / 1024
    )
  }

  # Maximum replica ceiling per role: the scaler's own maximum when the module
  # owns scaling, otherwise the fixed replica count the caller configured
  # (mirrors the n8n.tf replica-count wiring for each scaler switch). Main
  # uses the same effective, single-main-clamped ceiling n8n.tf's main HPA
  # renders (locals.tf's n8n_effective_main_hpa_max_replicas), so a caller-
  # configured maximum above 1 does not overstate capacity while single-main
  # is selected.
  capacity_main_max_replicas    = var.n8n_main_hpa_enabled ? local.n8n_effective_main_hpa_max_replicas : var.n8n_main_fixed_replicas
  capacity_worker_max_replicas  = var.n8n_worker_keda_enabled ? var.n8n_worker_keda_max_replicas : var.n8n_worker_fixed_replicas
  capacity_webhook_max_replicas = var.n8n_webhook_hpa_enabled ? var.n8n_webhook_hpa_max_replicas : var.n8n_webhook_fixed_replicas

  # Task runners run as a sidecar container inside every worker pod (n8n.tf
  # taskRunners block), never webhook-processor pods. Whether main also gets
  # one depends on the pinned chart: n8n-hosting#179 (n8n.mainTaskRunnersEnabled)
  # gates the main sidecar on standalone mode only, shipped in chart 1.12.0 and
  # unchanged through 1.14.0 (verified by diffing deployment-main.yaml between
  # each release). Since this module always runs queue mode, main carries no
  # sidecar on those verified releases; an unverified n8n_chart_version
  # (a different mirror, a preview build such as examples/worker-pools'
  # "1.11.0-preview.workerpools.1", or a future/older numbered release) keeps
  # the conservative allowance: an older or unrelated chart may still render
  # the main sidecar, and this module cannot see which templates an
  # arbitrary pin actually renders. Same shape
  # as terraform-aws-n8n's/terraform-azurerm-n8n's own
  # n8n_chart_has_worker_only_runners. tests/scripts/check-n8n-chart.sh
  # asserts the rendered main Deployment has no task-runner container at the
  # pinned default.
  n8n_chart_has_worker_only_runners = (
    var.n8n_chart_repository == "oci://ghcr.io/n8n-io/n8n-helm-chart" &&
    contains(["1.12.0", "1.13.0", "1.14.0"], split("+", var.n8n_chart_version)[0])
  )
  capacity_main_task_runner_cpu_millis = (var.n8n_task_runners_enabled && !local.n8n_chart_has_worker_only_runners) ? local.capacity_cpu_millicores_by_role.task_runner : 0
  capacity_main_task_runner_memory_mib = (var.n8n_task_runners_enabled && !local.n8n_chart_has_worker_only_runners) ? local.capacity_memory_mib_by_role.task_runner : 0
  # The opt-in Redis exporter (observability.tf) runs one fixed-size replica
  # regardless of any scaler, so its requests add a flat amount rather than
  # multiplying by a replica ceiling. Matches the resources block in
  # observability.tf; keep the two in sync.
  capacity_exporter_cpu_millicores = var.redis_exporter_enabled ? 10 : 0
  capacity_exporter_memory_mib     = var.redis_exporter_enabled ? 32 : 0

  # Worker pools (worker-pools.tf, EARLY ALPHA): each pool's own max_replicas
  # ceiling, at its own resolved request (falling back to the module-wide
  # worker request the same way n8n_worker_groups does), plus a task runner
  # sidecar per replica while n8n_task_runners_enabled -- pool workers get the
  # same taskRunners sidecar every other worker pod gets (n8n.tf).
  capacity_pool_cpu_millicores = [
    for p in var.n8n_worker_pools : (
      endswith(coalesce(p.cpu_request, var.n8n_worker_cpu_request), "m")
      ? tonumber(trimsuffix(coalesce(p.cpu_request, var.n8n_worker_cpu_request), "m"))
      : tonumber(coalesce(p.cpu_request, var.n8n_worker_cpu_request)) * 1000
    )
  ]

  capacity_pool_memory_mib = [
    for p in var.n8n_worker_pools : (
      endswith(coalesce(p.memory_request, var.n8n_worker_memory_request), "Gi") ? tonumber(trimsuffix(coalesce(p.memory_request, var.n8n_worker_memory_request), "Gi")) * 1024 :
      endswith(coalesce(p.memory_request, var.n8n_worker_memory_request), "Mi") ? tonumber(trimsuffix(coalesce(p.memory_request, var.n8n_worker_memory_request), "Mi")) :
      endswith(coalesce(p.memory_request, var.n8n_worker_memory_request), "Ki") ? tonumber(trimsuffix(coalesce(p.memory_request, var.n8n_worker_memory_request), "Ki")) / 1024 :
      tonumber(coalesce(p.memory_request, var.n8n_worker_memory_request)) / 1024 / 1024
    )
  ]

  capacity_pool_peak_cpu_millicores = sum(concat([0], [
    for i, p in var.n8n_worker_pools :
    p.max_replicas * (local.capacity_pool_cpu_millicores[i] + (var.n8n_task_runners_enabled ? local.capacity_cpu_millicores_by_role.task_runner : 0))
  ]))

  capacity_pool_peak_memory_mib = sum(concat([0], [
    for i, p in var.n8n_worker_pools :
    p.max_replicas * (local.capacity_pool_memory_mib[i] + (var.n8n_task_runners_enabled ? local.capacity_memory_mib_by_role.task_runner : 0))
  ]))

  capacity_requested_max_cpu_millicores = (
    local.capacity_main_max_replicas * (local.capacity_cpu_millicores_by_role.main + local.capacity_main_task_runner_cpu_millis) +
    local.capacity_worker_max_replicas * (local.capacity_cpu_millicores_by_role.worker + (var.n8n_task_runners_enabled ? local.capacity_cpu_millicores_by_role.task_runner : 0)) +
    local.capacity_webhook_max_replicas * local.capacity_cpu_millicores_by_role.webhook +
    local.capacity_exporter_cpu_millicores +
    local.capacity_pool_peak_cpu_millicores
  )

  capacity_requested_max_memory_mib = (
    local.capacity_main_max_replicas * (local.capacity_memory_mib_by_role.main + local.capacity_main_task_runner_memory_mib) +
    local.capacity_worker_max_replicas * (local.capacity_memory_mib_by_role.worker + (var.n8n_task_runners_enabled ? local.capacity_memory_mib_by_role.task_runner : 0)) +
    local.capacity_webhook_max_replicas * local.capacity_memory_mib_by_role.webhook +
    local.capacity_exporter_memory_mib +
    local.capacity_pool_peak_memory_mib
  )
}

# Fires only for module-managed GKE (create_gke = true). A capacity estimate
# of zero (e.g. an unresolvable machine-type lookup) is treated as "nothing
# reliable to compare against" and silently skipped, the same as existing GKE,
# rather than assumed to mean zero capacity.
check "gke_capacity_cpu_fits_requested_replicas" {
  assert {
    condition = (
      !var.create_gke ||
      local.capacity_total_allocatable_cpu_millicores <= 0 ||
      local.capacity_requested_max_cpu_millicores <= local.capacity_total_allocatable_cpu_millicores
    )
    error_message = join("", [
      "Estimated managed GKE node-pool CPU capacity (~", format("%.1f", local.capacity_total_allocatable_cpu_millicores / 1000),
      " allocatable cores across up to ${local.capacity_total_nodes} ${var.gke_node_type} node(s): ",
      "${var.gke_node_max_per_zone} per zone x ${local.capacity_zone_count} zones) is below the CPU the configured ",
      "main, worker, webhook, and task-runner replica ceilings, plus the optional Redis exporter and any n8n_worker_pools ",
      "(${length(var.n8n_worker_pools)} pool(s), ~", format("%.1f", local.capacity_pool_peak_cpu_millicores / 1000), " cores at their maxima), could request at their maximum (~",
      format("%.1f", local.capacity_requested_max_cpu_millicores / 1000), " cores). This is a non-blocking, ",
      "documented estimate (GKE's per-node system-reserve formula), not a live read of the node pool. The cluster ",
      "autoscaler never exceeds gke_node_max_per_zone, so pods that do not fit once the pool reaches that ceiling go ",
      "Pending. Raise gke_node_type, gke_node_max_per_zone, or lower the requested replica maxima (including any ",
      "n8n_worker_pools max_replicas) to silence this warning.",
    ])
  }
}

check "gke_capacity_memory_fits_requested_replicas" {
  assert {
    condition = (
      !var.create_gke ||
      local.capacity_total_allocatable_memory_mib <= 0 ||
      local.capacity_requested_max_memory_mib <= local.capacity_total_allocatable_memory_mib
    )
    error_message = join("", [
      "Estimated managed GKE node-pool memory capacity (~", format("%.1f", local.capacity_total_allocatable_memory_mib / 1024),
      " allocatable GiB across up to ${local.capacity_total_nodes} ${var.gke_node_type} node(s): ",
      "${var.gke_node_max_per_zone} per zone x ${local.capacity_zone_count} zones) is below the memory the configured ",
      "main, worker, webhook, and task-runner replica ceilings, plus the optional Redis exporter and any n8n_worker_pools ",
      "(${length(var.n8n_worker_pools)} pool(s), ~", format("%.1f", local.capacity_pool_peak_memory_mib / 1024), " GiB at their maxima), could request at their maximum (~",
      format("%.1f", local.capacity_requested_max_memory_mib / 1024), " GiB). This is a non-blocking, documented ",
      "estimate (GKE's per-node system-reserve formula), not a live read of the node pool. The cluster autoscaler ",
      "never exceeds gke_node_max_per_zone, so pods that do not fit once the pool reaches that ceiling go Pending. ",
      "Raise gke_node_type, gke_node_max_per_zone, or lower the requested replica maxima (including any ",
      "n8n_worker_pools max_replicas) to silence this warning.",
    ])
  }
}
