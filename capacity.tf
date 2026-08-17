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

# Zones available to a regional GKE cluster in gcp_region; a regional cluster
# schedules across all of them, so the node pool's total capacity scales with
# this count, not with a single zone.
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
  capacity_zone_count = var.create_gke ? length(data.google_compute_zones.gke[0].names) : 0

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
  # (mirrors the n8n.tf replica-count wiring for each scaler switch).
  capacity_main_max_replicas    = var.n8n_main_hpa_enabled ? var.n8n_main_hpa_max_replicas : var.n8n_main_fixed_replicas
  capacity_worker_max_replicas  = var.n8n_worker_keda_enabled ? var.n8n_worker_keda_max_replicas : var.n8n_worker_fixed_replicas
  capacity_webhook_max_replicas = var.n8n_webhook_hpa_enabled ? var.n8n_webhook_hpa_max_replicas : var.n8n_webhook_fixed_replicas

  # Task runners run as a sidecar container inside every main and worker pod
  # (n8n.tf taskRunners block), never webhook-processor pods, so their
  # resource requests are added once per main replica and once per worker
  # replica, only while n8n_task_runners_enabled.
  capacity_requested_max_cpu_millicores = (
    local.capacity_main_max_replicas * (local.capacity_cpu_millicores_by_role.main + (var.n8n_task_runners_enabled ? local.capacity_cpu_millicores_by_role.task_runner : 0)) +
    local.capacity_worker_max_replicas * (local.capacity_cpu_millicores_by_role.worker + (var.n8n_task_runners_enabled ? local.capacity_cpu_millicores_by_role.task_runner : 0)) +
    local.capacity_webhook_max_replicas * local.capacity_cpu_millicores_by_role.webhook
  )

  capacity_requested_max_memory_mib = (
    local.capacity_main_max_replicas * (local.capacity_memory_mib_by_role.main + (var.n8n_task_runners_enabled ? local.capacity_memory_mib_by_role.task_runner : 0)) +
    local.capacity_worker_max_replicas * (local.capacity_memory_mib_by_role.worker + (var.n8n_task_runners_enabled ? local.capacity_memory_mib_by_role.task_runner : 0)) +
    local.capacity_webhook_max_replicas * local.capacity_memory_mib_by_role.webhook
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
      "main, worker, webhook, and task-runner replica ceilings could request at their maximum (~",
      format("%.1f", local.capacity_requested_max_cpu_millicores / 1000), " cores). This is a non-blocking, ",
      "documented estimate (GKE's per-node system-reserve formula), not a live read of the node pool: pods may ",
      "still schedule if GKE's cluster autoscaler grows beyond gke_node_max_per_zone, or may go Pending if it ",
      "cannot. Raise gke_node_type, gke_node_max_per_zone, or lower the requested replica maxima to silence this warning.",
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
      "main, worker, webhook, and task-runner replica ceilings could request at their maximum (~",
      format("%.1f", local.capacity_requested_max_memory_mib / 1024), " GiB). This is a non-blocking, documented ",
      "estimate (GKE's per-node system-reserve formula), not a live read of the node pool: pods may still schedule ",
      "if GKE's cluster autoscaler grows beyond gke_node_max_per_zone, or may go Pending if it cannot. Raise ",
      "gke_node_type, gke_node_max_per_zone, or lower the requested replica maxima to silence this warning.",
    ])
  }
}
