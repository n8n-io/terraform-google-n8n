# Plan-time tests for the section 2 network and Private Service Access
# ownership: count-gating the VPC/subnetwork/router/NAT (create_network) and
# the Private Service Access allocation/connection (create_psa) independently,
# and wiring existing-network/existing-PSA references into the effective
# locals that managed GKE, Cloud SQL, and Memorystore consume.

mock_provider "google" {}
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
}

# ── Defaults create every managed network resource ────────────────────────────

run "defaults_create_managed_network_resources" {
  command = plan

  assert {
    condition     = length(google_compute_network.n8n) == 1
    error_message = "create_network defaults to true and must create the VPC."
  }

  assert {
    condition     = length(google_compute_subnetwork.n8n) == 1
    error_message = "create_network defaults to true and must create the subnetwork."
  }

  assert {
    condition     = length(google_compute_router.n8n) == 1
    error_message = "create_network defaults to true and must create the Cloud Router."
  }

  assert {
    condition     = length(google_compute_router_nat.n8n) == 1
    error_message = "create_network defaults to true and must create Cloud NAT."
  }

  assert {
    condition     = length(google_compute_global_address.psa) == 1
    error_message = "create_psa defaults to true and must create the PSA range."
  }

  assert {
    condition     = length(google_service_networking_connection.psa) == 1
    error_message = "create_psa defaults to true and must create the PSA connection."
  }

  assert {
    condition     = length(time_sleep.wait_for_psa_cleanup) == 1
    error_message = "create_psa defaults to true and must create the PSA cleanup delay."
  }
}

# ── Existing network omits every module-owned network resource ───────────────

run "existing_network_creates_no_network_resources" {
  command = plan

  variables {
    create_network               = false
    existing_network_name        = "shared-vpc"
    existing_subnetwork_name     = "shared-subnet"
    existing_pods_range_name     = "shared-pods"
    existing_services_range_name = "shared-services"
  }

  assert {
    condition     = length(google_compute_network.n8n) == 0
    error_message = "create_network = false must not create a VPC."
  }

  assert {
    condition     = length(google_compute_subnetwork.n8n) == 0
    error_message = "create_network = false must not create a subnetwork."
  }

  assert {
    condition     = length(google_compute_router.n8n) == 0
    error_message = "create_network = false must not create a Cloud Router."
  }

  assert {
    condition     = length(google_compute_router_nat.n8n) == 0
    error_message = "create_network = false must not create Cloud NAT."
  }

  # PSA ownership is independent of network ownership; it still defaults to
  # module-managed on an existing network.
  assert {
    condition     = length(google_compute_global_address.psa) == 1
    error_message = "create_psa still defaults to true on an existing network."
  }

  assert {
    condition     = google_compute_global_address.psa[0].network == "projects/test-project/global/networks/shared-vpc"
    error_message = "The module-managed PSA range must attach to the existing network, not a module-owned one."
  }
}

# ── Existing PSA omits the module-owned PSA range and connection ─────────────

run "existing_psa_creates_no_psa_resources" {
  command = plan

  variables {
    create_psa                             = false
    existing_psa_prerequisites_attestation = true
  }

  assert {
    condition     = length(google_compute_global_address.psa) == 0
    error_message = "create_psa = false must not create a PSA range."
  }

  assert {
    condition     = length(google_service_networking_connection.psa) == 0
    error_message = "create_psa = false must not create a PSA connection."
  }

  assert {
    condition     = length(time_sleep.wait_for_psa_cleanup) == 0
    error_message = "create_psa = false must not create the PSA cleanup delay."
  }

  # The module still owns the VPC by default.
  assert {
    condition     = length(google_compute_network.n8n) == 1
    error_message = "create_network still defaults to true when only PSA is customer-managed."
  }
}

# ── Existing network AND existing PSA together ────────────────────────────────

run "existing_network_and_existing_psa_creates_no_network_or_psa_resources" {
  command = plan

  variables {
    create_network                         = false
    existing_network_name                  = "shared-vpc"
    existing_subnetwork_name               = "shared-subnet"
    existing_pods_range_name               = "shared-pods"
    existing_services_range_name           = "shared-services"
    create_psa                             = false
    existing_psa_prerequisites_attestation = true
  }

  assert {
    condition = (
      length(google_compute_network.n8n) == 0 &&
      length(google_compute_subnetwork.n8n) == 0 &&
      length(google_compute_router.n8n) == 0 &&
      length(google_compute_router_nat.n8n) == 0 &&
      length(google_compute_global_address.psa) == 0 &&
      length(google_service_networking_connection.psa) == 0 &&
      length(time_sleep.wait_for_psa_cleanup) == 0
    )
    error_message = "A fully customer-managed network and PSA must create none of the module's network or PSA resources."
  }
}

# ── Managed data services wire to the correct network ─────────────────────────

run "managed_gke_and_data_services_wire_to_existing_network" {
  command = plan

  variables {
    create_network               = false
    existing_network_name        = "shared-vpc"
    existing_subnetwork_name     = "shared-subnet"
    existing_pods_range_name     = "shared-pods"
    existing_services_range_name = "shared-services"
  }

  assert {
    condition     = google_container_cluster.n8n[0].network == "projects/test-project/global/networks/shared-vpc"
    error_message = "Managed GKE must attach to the existing network when create_network = false."
  }

  assert {
    condition     = google_container_cluster.n8n[0].subnetwork == "projects/test-project/regions/us-east4/subnetworks/shared-subnet"
    error_message = "Managed GKE must attach to the existing subnetwork when create_network = false."
  }

  assert {
    condition = (
      google_container_cluster.n8n[0].ip_allocation_policy[0].cluster_secondary_range_name == "shared-pods" &&
      google_container_cluster.n8n[0].ip_allocation_policy[0].services_secondary_range_name == "shared-services"
    )
    error_message = "Managed GKE must use the existing secondary range names when create_network = false."
  }

  assert {
    condition     = google_sql_database_instance.n8n[0].settings[0].ip_configuration[0].private_network == "projects/test-project/global/networks/shared-vpc"
    error_message = "Managed Cloud SQL must attach to the existing network when create_network = false."
  }

  assert {
    condition     = google_redis_instance.n8n[0].authorized_network == "projects/test-project/global/networks/shared-vpc"
    error_message = "Managed Memorystore must attach to the existing network when create_network = false."
  }
}

run "shared_vpc_host_project_is_honored" {
  command = plan

  variables {
    create_network               = false
    existing_network_name        = "shared-vpc"
    existing_network_project_id  = "host-project"
    existing_subnetwork_name     = "shared-subnet"
    existing_pods_range_name     = "shared-pods"
    existing_services_range_name = "shared-services"
  }

  assert {
    condition     = google_container_cluster.n8n[0].network == "projects/host-project/global/networks/shared-vpc"
    error_message = "The Shared VPC host project must be used when existing_network_project_id differs from project_id."
  }

  assert {
    condition     = google_compute_global_address.psa[0].project == "host-project"
    error_message = "The module-managed PSA allocation must be created in the Shared VPC host project."
  }
}

# ── Opposite-path diagnostics ─────────────────────────────────────────────────

run "psa_tuning_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_psa                             = false
    existing_psa_prerequisites_attestation = true
    psa_prefix_length                      = 20
  }

  expect_failures = [check.psa_tuning_ignored_when_existing]
}

run "network_references_ignored_when_managed_triggers_warning" {
  command = plan

  variables {
    existing_network_name = "shared-vpc"
  }

  expect_failures = [check.network_references_ignored_when_managed]
}
