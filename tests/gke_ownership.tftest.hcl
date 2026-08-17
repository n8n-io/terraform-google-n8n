# Plan-time tests for the section 3 GKE ownership: count-gating the cluster,
# node pool, node service account, and node IAM (create_gke), the existing-GKE
# data lookup and its observable compatibility postconditions, and the
# ownership-neutral effective GKE locals/outputs each path resolves to.

# mock_data "google_container_cluster" defaults to a compatible cluster
# (VPC-native, Workload Identity enabled, same-project pool); individual runs
# use override_data to exercise the incompatible-cluster postconditions.
mock_provider "google" {
  mock_data "google_container_cluster" {
    defaults = {
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
}
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

# ── Defaults create every managed GKE resource ────────────────────────────────

run "defaults_create_managed_gke_resources" {
  command = plan

  assert {
    condition     = length(google_container_cluster.n8n) == 1
    error_message = "create_gke defaults to true and must create the GKE cluster."
  }

  assert {
    condition     = length(google_container_node_pool.n8n) == 1
    error_message = "create_gke defaults to true and must create the node pool."
  }

  assert {
    condition     = length(google_service_account.nodes) == 1
    error_message = "create_gke defaults to true and must create the node service account."
  }

  assert {
    condition     = length(google_project_iam_member.nodes) == 5
    error_message = "create_gke defaults to true and must create the node IAM bindings."
  }

  assert {
    condition     = length(data.google_container_cluster.existing) == 0
    error_message = "create_gke defaults to true and must not read an existing cluster."
  }
}

# ── Existing GKE creates no cluster-only resources ────────────────────────────

run "existing_gke_creates_no_cluster_resources" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
  }

  assert {
    condition     = length(google_container_cluster.n8n) == 0
    error_message = "create_gke = false must not create a GKE cluster."
  }

  assert {
    condition     = length(google_container_node_pool.n8n) == 0
    error_message = "create_gke = false must not create a node pool."
  }

  assert {
    condition     = length(google_service_account.nodes) == 0
    error_message = "create_gke = false must not create a node service account."
  }

  assert {
    condition     = length(google_project_iam_member.nodes) == 0
    error_message = "create_gke = false must not create node IAM bindings."
  }

  assert {
    condition     = length(data.google_container_cluster.existing) == 1
    error_message = "create_gke = false must read the existing cluster."
  }

  assert {
    condition     = output.gke_cluster_name == "shared-cluster"
    error_message = "gke_cluster_name should resolve to existing_gke_cluster_name."
  }

  assert {
    condition     = output.gke_cluster_endpoint == "10.0.0.2"
    error_message = "gke_cluster_endpoint should resolve to the existing cluster's endpoint."
  }

  assert {
    condition     = output.gke_cluster_ca_certificate == "ZmFrZS1jYQ=="
    error_message = "gke_cluster_ca_certificate should resolve to the existing cluster's CA."
  }

  assert {
    condition     = output.workload_identity_pool == "test-project.svc.id.goog"
    error_message = "workload_identity_pool should resolve to the existing cluster's observed pool."
  }
}

# ── Existing GKE with a cross-project Workload Identity pool ─────────────────

run "existing_gke_cross_project_pool_requires_explicit_override" {
  command = plan

  variables {
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
      workload_identity_config = [{ workload_pool = "other-project.svc.id.goog" }]
    }
  }

  expect_failures = [data.google_container_cluster.existing]
}

run "existing_gke_cross_project_pool_accepted_with_override" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
    existing_gke_workload_identity_pool    = "other-project.svc.id.goog"
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
      workload_identity_config = [{ workload_pool = "other-project.svc.id.goog" }]
    }
  }

  assert {
    condition     = output.workload_identity_pool == "other-project.svc.id.goog"
    error_message = "workload_identity_pool should track the explicit cross-project override."
  }
}

# ── Existing GKE with an incompatible networking mode fails the plan ─────────

run "existing_gke_non_vpc_native_fails" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
  }

  override_data {
    target = data.google_container_cluster.existing
    values = {
      endpoint        = "10.0.0.2"
      networking_mode = "ROUTES"
      master_auth = [{
        client_certificate        = ""
        client_certificate_config = []
        client_key                = ""
        cluster_ca_certificate    = "ZmFrZS1jYQ=="
      }]
      workload_identity_config = [{ workload_pool = "test-project.svc.id.goog" }]
    }
  }

  expect_failures = [data.google_container_cluster.existing]
}

# ── Existing GKE without Workload Identity enabled fails the plan ────────────

run "existing_gke_without_workload_identity_fails" {
  command = plan

  variables {
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
      workload_identity_config = []
    }
  }

  expect_failures = [data.google_container_cluster.existing]
}

# ── Managed GKE ignores existing-cluster references ───────────────────────────
# Regression: a stray existing_gke_workload_identity_pool set while the module
# manages the cluster must never rewrite the Workload Identity binding; the
# managed branch is pinned to this project's own pool (locals.tf). The
# ignored-input check fires as a warning and must be listed in
# expect_failures (see AGENTS.md), while the asserts prove the pool and the
# IAM binding member stay on the managed cluster's own pool.

run "managed_gke_ignores_existing_workload_identity_pool" {
  command = plan

  variables {
    existing_gke_workload_identity_pool = "other-project.svc.id.goog"
  }

  assert {
    condition     = output.workload_identity_pool == "test-project.svc.id.goog"
    error_message = "workload_identity_pool must stay on the managed cluster's own pool; existing_gke_workload_identity_pool is ignored when create_gke = true."
  }

  assert {
    condition     = google_service_account_iam_member.n8n_workload_identity.member == "serviceAccount:test-project.svc.id.goog[n8n/n8n]"
    error_message = "The Workload Identity binding member must use the managed cluster's own pool, not the ignored existing_gke_workload_identity_pool."
  }

  expect_failures = [check.gke_references_ignored_when_managed]
}

# The new opposite-path diagnostic itself: any existing-cluster reference set
# while create_gke = true warns (and only warns; the ignored inputs change
# nothing).

run "gke_references_ignored_when_managed_triggers_warning" {
  command = plan

  variables {
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
  }

  assert {
    condition     = length(data.google_container_cluster.existing) == 0
    error_message = "create_gke = true must not read the (ignored) existing cluster reference."
  }

  expect_failures = [check.gke_references_ignored_when_managed]
}
