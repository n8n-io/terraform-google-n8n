# Plan-time tests for section 12 capacity guardrails: the managed GKE
# machine-type/zone lookup, the regional node-pool allocatable CPU/memory
# estimate, the non-blocking check blocks comparing that estimate with the
# maximum main/worker/webhook/task-runner replica requests, and the
# existing-GKE skip.
#
# mock_data "google_compute_zones" and "google_compute_machine_types" default
# to a 3-zone region and the default e2-standard-4 shape; individual runs use
# override_data to size the node pool for each scenario. Requested capacity at
# the module's defaults (n8n_main_hpa_max_replicas=20,
# n8n_worker_keda_max_replicas=10, n8n_webhook_hpa_max_replicas=50,
# n8n_task_runners_enabled=true) is a fixed ~46 cores / ~90GiB; the machine
# shapes below are chosen against that fixed target (see the change's task
# 12.3 verification notes for the arithmetic).
mock_provider "google" {
  mock_data "google_compute_zones" {
    defaults = {
      names = ["us-east4-a", "us-east4-b", "us-east4-c"]
    }
  }

  mock_data "google_compute_machine_types" {
    defaults = {
      machine_types = [{
        name       = "e2-standard-4"
        guest_cpus = 4
        memory_mb  = 16384
      }]
    }
  }
}
mock_provider "google-beta" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "helm" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  project_id           = "test-project"
  gcp_region           = "us-east4"
  friendly_name_prefix = "test"
  n8n_fqdn             = "n8n.test.example.com"
  n8n_license_key      = "test-license-key-not-real"

  # Every sized run below was calibrated against a 6-node ceiling (2 per zone x
  # 3 zones). Pin it here so the module default (4) does not shift their math;
  # the default itself is exercised explicitly in
  # defaults_fit_the_default_node_pool_ceiling and asserted in
  # tests/defaults.tftest.hcl.
  gke_node_max_per_zone = 2
}

# ── Estimate wiring ────────────────────────────────────────────────────────────

run "capacity_estimate_scales_with_zone_count_and_node_max" {
  command = plan

  override_data {
    target = data.google_compute_zones.gke
    values = {
      names = ["us-east4-a", "us-east4-b", "us-east4-c"]
    }
  }

  override_data {
    target = data.google_compute_machine_types.gke
    values = {
      machine_types = [{
        name       = "e2-standard-4"
        guest_cpus = 4
        memory_mb  = 16384
      }]
    }
  }

  assert {
    condition     = local.capacity_zone_count == 3
    error_message = "capacity_zone_count must reflect the number of zones the region data source returns."
  }

  assert {
    condition     = local.capacity_total_nodes == var.gke_node_max_per_zone * 3
    error_message = "capacity_total_nodes must be gke_node_max_per_zone times the node pool's zone count (three zones for a regional pool with default node_locations)."
  }

  assert {
    condition     = local.capacity_allocatable_cpu_millicores_per_node < 4000
    error_message = "Per-node allocatable CPU must be less than the raw 4 cores (4000m) once GKE's system-reserve tiers are subtracted."
  }

  assert {
    condition     = local.capacity_allocatable_memory_mib_per_node < 16384
    error_message = "Per-node allocatable memory must be less than the raw 16384MiB once GKE's system-reserve tiers are subtracted."
  }

  # At the historical 2-per-zone ceiling (6 e2-standard-4 nodes) the default
  # replica maxima (n8n_main_hpa_max_replicas=20, n8n_worker_keda_max_replicas=10,
  # n8n_webhook_hpa_max_replicas=50) cannot be hosted at full scale-out, so
  # both checks fire. That is the finding the guardrail exists to surface; the
  # module default was raised to 4 per zone so a default deployment no longer
  # trips its own guardrail (see the run below).
  expect_failures = [
    check.gke_capacity_cpu_fits_requested_replicas,
    check.gke_capacity_memory_fits_requested_replicas,
  ]
}

# ── Module defaults pass the guardrail ────────────────────────────────────────
# gke_node_max_per_zone = 4 is the module default (tests/defaults.tftest.hcl
# asserts the value on the node pool); it is set explicitly here only because
# this file pins 2 at file level. 12 e2-standard-4 nodes must cover the default
# replica maxima so a stock deployment emits no capacity warning.

run "defaults_fit_the_default_node_pool_ceiling" {
  command = plan

  variables {
    gke_node_max_per_zone = 4
  }

  override_data {
    target = data.google_compute_zones.gke
    values = {
      names = ["us-east4-a", "us-east4-b", "us-east4-c"]
    }
  }

  override_data {
    target = data.google_compute_machine_types.gke
    values = {
      machine_types = [{
        name       = "e2-standard-4"
        guest_cpus = 4
        memory_mb  = 16384
      }]
    }
  }

  assert {
    condition     = local.capacity_total_nodes == 12
    error_message = "The default ceiling must be 12 nodes (4 per zone x 3 zones)."
  }

  assert {
    condition     = local.capacity_requested_max_cpu_millicores <= local.capacity_total_allocatable_cpu_millicores
    error_message = "The module's default replica maxima must fit the default node-pool CPU ceiling, or a stock deployment warns on every plan."
  }

  assert {
    condition     = local.capacity_requested_max_memory_mib <= local.capacity_total_allocatable_memory_mib
    error_message = "The module's default replica maxima must fit the default node-pool memory ceiling, or a stock deployment warns on every plan."
  }
}

# ── Zone count is capped at GKE's three default node locations ────────────────
# The module sets no node_locations, so GKE places the pool in three zones even
# in a four-zone region; counting every UP zone would overstate capacity.

run "capacity_zone_count_caps_at_three_default_node_locations" {
  command = plan

  override_data {
    target = data.google_compute_zones.gke
    values = {
      names = ["us-central1-a", "us-central1-b", "us-central1-c", "us-central1-f"]
    }
  }

  override_data {
    target = data.google_compute_machine_types.gke
    values = {
      machine_types = [{
        name       = "e2-standard-4"
        guest_cpus = 4
        memory_mb  = 16384
      }]
    }
  }

  assert {
    condition     = local.capacity_zone_count == 3 && local.capacity_total_nodes == 6
    error_message = "A four-zone region must still estimate against three zones, GKE's default node_locations for a regional pool."
  }

  expect_failures = [
    check.gke_capacity_cpu_fits_requested_replicas,
    check.gke_capacity_memory_fits_requested_replicas,
  ]
}

run "capacity_check_skips_existing_gke" {
  command = plan

  variables {
    # Back to the module default: the file-level pin of 2 would otherwise trip
    # checks.tf's gke_tuning_ignored_when_existing on this existing-GKE run.
    gke_node_max_per_zone                  = 4
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
  }

  override_data {
    target = data.google_container_cluster.existing
    values = {
      endpoint        = "10.0.0.2"
      networking_mode = "VPC_NATIVE"
      master_auth = [{
        client_certificate        = ""
        client_certificate_config = []
        client_key                = ""
        cluster_ca_certificate    = "ZmFrZS1jYQ=="
      }]
      workload_identity_config = [{ workload_pool = "test-project.svc.id.goog" }]
    }
  }

  assert {
    condition     = length(data.google_compute_zones.gke) == 0
    error_message = "create_gke = false must not run the zone lookup used for the capacity estimate."
  }

  assert {
    condition     = length(data.google_compute_machine_types.gke) == 0
    error_message = "create_gke = false must not run the machine-type lookup used for the capacity estimate."
  }

  assert {
    condition     = local.capacity_zone_count == 0 && local.capacity_total_allocatable_cpu_millicores == 0 && local.capacity_total_allocatable_memory_mib == 0
    error_message = "create_gke = false must produce no computed capacity verdict (12: existing GKE capacity is not guessed)."
  }
}

# ── Fits / does not fit ───────────────────────────────────────────────────────

run "capacity_fits_with_a_generously_sized_node_pool" {
  command = plan

  override_data {
    target = data.google_compute_machine_types.gke
    values = {
      machine_types = [{
        name       = "custom-16-65536"
        guest_cpus = 16
        memory_mb  = 65536
      }]
    }
  }
}

run "capacity_warns_when_cpu_is_insufficient" {
  command = plan

  override_data {
    target = data.google_compute_machine_types.gke
    values = {
      machine_types = [{
        name       = "custom-1-65536"
        guest_cpus = 1
        memory_mb  = 65536
      }]
    }
  }

  expect_failures = [check.gke_capacity_cpu_fits_requested_replicas]
}

run "capacity_warns_when_memory_is_insufficient" {
  command = plan

  override_data {
    target = data.google_compute_machine_types.gke
    values = {
      machine_types = [{
        name       = "custom-64-2048"
        guest_cpus = 64
        memory_mb  = 2048
      }]
    }
  }

  expect_failures = [check.gke_capacity_memory_fits_requested_replicas]
}

# ── Task-runner sidecar overhead ───────────────────────────────────────────────
# Same node-pool shape, sized so the estimate covers the default replica
# maxima's CPU request without the task-runner sidecar, but not with it (the
# sidecar adds its own CPU request to every main and worker pod, n8n.tf's
# taskRunners block).

run "capacity_fits_without_task_runner_overhead" {
  command = plan

  variables {
    n8n_task_runners_enabled = false
  }

  override_data {
    target = data.google_compute_machine_types.gke
    values = {
      machine_types = [{
        name       = "custom-7-65536"
        guest_cpus = 7
        memory_mb  = 65536
      }]
    }
  }
}

run "capacity_warns_once_task_runner_overhead_is_added" {
  command = plan

  variables {
    n8n_task_runners_enabled = true
  }

  override_data {
    target = data.google_compute_machine_types.gke
    values = {
      machine_types = [{
        name       = "custom-7-65536"
        guest_cpus = 7
        memory_mb  = 65536
      }]
    }
  }

  expect_failures = [check.gke_capacity_cpu_fits_requested_replicas]
}

# ── Unresolvable estimate is skipped, not assumed insufficient ────────────────

run "capacity_check_skips_when_machine_type_is_unresolvable" {
  command = plan

  override_data {
    target = data.google_compute_machine_types.gke
    values = {
      machine_types = []
    }
  }

  assert {
    condition     = local.capacity_total_allocatable_cpu_millicores == 0 && local.capacity_total_allocatable_memory_mib == 0
    error_message = "An empty machine-type lookup result must resolve to a zero estimate, which the check blocks treat as unresolvable and skip."
  }
}
