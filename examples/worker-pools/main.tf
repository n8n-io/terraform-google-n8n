# ── Example: worker pools (EARLY ALPHA) ──────────────────────────────────────
# Sizing-equivalent to examples/small apart from gke_node_max_per_zone, with
# one topology change: three labelled worker pools run beside the chart's own
# unlabelled worker deployment, each with its own replica bounds, sizing and
# autoscaler. See README.md for the full alpha-feature caveat this depends on:
# n8n >= 2.39.0, a feat:workerPools license entitlement, and a Helm chart that
# renders queueMode.workerGroups (no released chart does, as of n8n_chart_
# version's default upstream at the time of writing).

locals {
  # ── Worker pools ────────────────────────────────────────────────────────────
  # The topology this example exists to show, kept as a local rather than a
  # variable: it is the point of the example, not a knob, and a local is
  # reachable from tests/defaults.tftest.hcl where a literal at the module call
  # site would not be.
  #
  # Each entry becomes its own worker Deployment plus its own KEDA ScaledObject
  # watching that pool's `jobs-<name>` queue. Assign a project to a pool in the
  # n8n UI under Project, Settings, Worker Pools; its executions then run only
  # on that pool's workers.
  #
  # A pool with no live workers is not an error. A job routed to it waits on
  # the pool's own queue and KEDA scales the pool up; measured live on
  # terraform-aws-n8n's own worker-pools example, 0 to 1 within one polling
  # interval, with the default queue untouched. What a parked pool cannot do
  # is be assigned for the first time: n8n lists a pool in a project's
  # settings only while one of its workers is registered. See the itop entry
  # below.
  worker_pools = [
    # Heavier executions, given more CPU and memory and a lower concurrency so
    # each worker takes fewer jobs at once. Still CPU-only: this example runs
    # the same node pool as small and sets no node placement, so "heavy" means
    # bigger requests, not different hardware.
    {
      name           = "heavy"
      min_replicas   = 1
      max_replicas   = 4
      concurrency    = 5
      cpu_request    = "1"
      cpu_limit      = "2"
      memory_request = "2Gi"
      memory_limit   = "4Gi"
    },

    # An isolated set for one team's projects, at the module's default worker
    # sizing.
    {
      name         = "secteam"
      min_replicas = 1
      max_replicas = 3
    },

    # Scales to zero when idle and wakes when a pinned project runs something;
    # the job waits on jobs-itop rather than falling back. Bootstrap caveat:
    # while itop has no running worker it does not appear in any project's
    # Worker Pools setting, so a project cannot be pinned to it. On a fresh
    # deployment set min_replicas = 1 here, assign the projects, then put it
    # back to 0; the stored assignment survives the scale-down.
    {
      name         = "itop"
      min_replicas = 0
      max_replicas = 3
    },
  ]
}

module "n8n" {
  source = "../.."

  project_id           = var.project_id
  gcp_region           = var.gcp_region
  friendly_name_prefix = var.friendly_name_prefix
  n8n_fqdn             = var.n8n_fqdn

  n8n_license_key = var.n8n_license_key
  n8n_image_tag   = var.n8n_image_tag
  gcs_location    = var.gcs_location

  # Set true only if your creds have org-policy admin (see variable docs).
  manage_sa_key_org_policy = var.manage_sa_key_org_policy

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  # ── Node capacity ───────────────────────────────────────────────────────────
  # The one place this example is not sizing-equivalent to examples/small.
  # Pools are additional autoscalers on the same node pool, and each can reach
  # its own ceiling independently, so their pods have to fit alongside the
  # main, default-worker and webhook ceilings rather than instead of them. At
  # the module's own defaults (main x20, worker x10, webhook x50, each with a
  # task-runner sidecar), the three pools above add roughly 9,000m of CPU
  # requests at their maxima on top of an already-tight ~46,000m baseline; the
  # module's default gke_node_max_per_zone of 4 (12 e2-standard-4 nodes,
  # ~47,040m allocatable) leaves no room. Raising it to 6 (18 nodes, ~70,560m)
  # covers both. The module warns at plan time when these fall out of step;
  # see check.gke_capacity_cpu_fits_requested_replicas in capacity.tf.
  gke_node_max_per_zone = var.gke_node_max_per_zone

  # ── Worker pools ────────────────────────────────────────────────────────────
  # Required by this example: the module default chart predates
  # queueMode.workerGroups and would render no pools. See README.md, "Getting
  # a chart that renders pools".
  n8n_chart_version               = var.n8n_chart_version
  n8n_chart_repository            = var.n8n_chart_repository
  n8n_worker_pools_chart_verified = var.n8n_worker_pools_chart_verified

  # The chart's own unlabelled worker deployment keeps serving the default
  # `jobs` queue for every project that is not pinned to a pool. Size it here.
  n8n_worker_keda_min_replicas = var.n8n_worker_keda_min_replicas
  n8n_worker_keda_max_replicas = var.n8n_worker_keda_max_replicas

  # The three pools this example exists to demonstrate. Declared at the top of
  # this file so the test file can assert on them; see the comment there.
  n8n_worker_pools = local.worker_pools

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  gke_deletion_protection      = var.gke_deletion_protection
  postgres_deletion_protection = var.postgres_deletion_protection
  gcs_force_destroy            = var.gcs_force_destroy

  # Backup tuning passthrough (both default null: provider's own default).
  postgres_backup_retained_backups        = var.postgres_backup_retained_backups
  postgres_transaction_log_retention_days = var.postgres_transaction_log_retention_days

  # Additional hostnames (default []: none).
  n8n_additional_domains = var.n8n_additional_domains

  # DNS + TLS: manage the record in Cloud DNS, Google-managed cert.
  cloud_dns_zone_name = var.cloud_dns_zone_name
  tls_mode            = "google_managed"
}
