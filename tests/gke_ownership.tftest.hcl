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

  # Explicit GKE hardening defaults curated for this change's Checkov
  # baseline (see the security baseline report): client-certificate auth
  # disabled, intranode visibility on, Dataplane V2 with the legacy
  # network-policy add-on left off, and Shielded-node Secure Boot/Integrity
  # Monitoring on both the (removed) default node pool template and the
  # actual managed node pool.
  assert {
    condition     = google_container_cluster.n8n[0].master_auth[0].client_certificate_config[0].issue_client_certificate == false
    error_message = "Client certificate authentication must stay disabled."
  }

  assert {
    condition     = google_container_cluster.n8n[0].enable_intranode_visibility == true
    error_message = "Intranode visibility must be enabled."
  }

  assert {
    condition     = google_container_cluster.n8n[0].datapath_provider == "ADVANCED_DATAPATH"
    error_message = "Dataplane V2 must be enabled."
  }

  assert {
    condition     = google_container_cluster.n8n[0].network_policy[0].enabled == false
    error_message = "The legacy Calico network-policy add-on must stay disabled alongside Dataplane V2."
  }

  assert {
    condition     = google_container_cluster.n8n[0].node_config[0].shielded_instance_config[0].enable_secure_boot == true && google_container_cluster.n8n[0].node_config[0].shielded_instance_config[0].enable_integrity_monitoring == true
    error_message = "The cluster's default node pool template must enable Secure Boot and Integrity Monitoring, matching the managed node pool."
  }

  assert {
    condition     = google_container_node_pool.n8n[0].node_config[0].shielded_instance_config[0].enable_secure_boot == true && google_container_node_pool.n8n[0].node_config[0].shielded_instance_config[0].enable_integrity_monitoring == true
    error_message = "The managed node pool must enable Secure Boot and Integrity Monitoring."
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

# ── Application-layer Secrets Encryption (Cloud KMS) ──────────────────────────

run "defaults_omit_database_encryption_and_secret_manager_addon" {
  command = plan

  assert {
    condition = (
      length(google_container_cluster.n8n[0].database_encryption) == 0 &&
      length(google_container_cluster.n8n[0].secret_manager_config) == 0
    )
    error_message = "Neither database_encryption nor secret_manager_config must render on the default plan."
  }

  assert {
    condition = (
      length(google_kms_crypto_key.gke) == 0 &&
      length(google_kms_crypto_key_iam_member.gke) == 0 &&
      length(google_project_service_identity.gke) == 0
    )
    error_message = "No GKE CMEK key, IAM grant, or service identity must be created by default."
  }
}

run "module_created_gke_key_wires_key_ring_and_iam" {
  command = plan

  variables {
    create_kms_key_ring = true
    create_gke_kms_key  = true
  }

  assert {
    condition     = length(google_kms_key_ring.n8n) == 1
    error_message = "create_kms_key_ring = true must create the shared key ring."
  }

  assert {
    condition     = length(google_kms_crypto_key.gke) == 1
    error_message = "create_gke_kms_key = true must create the GKE CryptoKey."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.gke) == 1
    error_message = "A module-created key must grant the GKE service agent IAM."
  }

  assert {
    condition = (
      length(google_project_service_identity.gke) == 1 &&
      google_project_service_identity.gke[0].project == "test-project" &&
      google_project_service_identity.gke[0].service == "container.googleapis.com"
    )
    error_message = "A module-created GKE key must materialize the target project's GKE service agent before granting IAM."
  }

  # database_encryption's key_name feeds from the module-created key's
  # computed id, which stays unknown under the mock provider at plan time
  # (see AGENTS.md, "Known mock provider limitations"); the rendered
  # database_encryption block itself is exercised with a known literal key
  # in existing_gke_key_creates_no_key_or_iam below instead.

  # CKV_GCP_43: every module-created CMEK key rotates within 90 days.
  assert {
    condition     = google_kms_crypto_key.gke[0].rotation_period == "7776000s"
    error_message = "A module-created GKE CryptoKey must rotate every 90 days."
  }
}

run "existing_gke_key_creates_no_key_or_iam" {
  command = plan

  variables {
    existing_gke_kms_key_id = "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/gke"
  }

  assert {
    condition     = length(google_kms_key_ring.n8n) == 0
    error_message = "An existing key must not require a module-managed key ring."
  }

  assert {
    condition     = length(google_kms_crypto_key.gke) == 0
    error_message = "An existing key must not be created."
  }

  assert {
    condition     = length(google_kms_crypto_key_iam_member.gke) == 0
    error_message = "An existing key must get no module-managed IAM grant."
  }

  assert {
    condition = (
      google_container_cluster.n8n[0].database_encryption[0].state == "ENCRYPTED" &&
      google_container_cluster.n8n[0].database_encryption[0].key_name == "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/gke"
    )
    error_message = "The managed cluster must use the supplied existing key."
  }
}

run "create_and_existing_gke_key_are_mutually_exclusive" {
  command = plan

  variables {
    create_gke_kms_key      = true
    existing_gke_kms_key_id = "projects/test-project/locations/us-east4/keyRings/shared/cryptoKeys/gke"
  }

  expect_failures = [var.create_gke_kms_key]
}

run "module_created_gke_key_without_ring_reference_fails" {
  command = plan

  variables {
    create_gke_kms_key = true
    # create_kms_key_ring left false and existing_kms_key_ring_id unset.
  }

  expect_failures = [var.existing_kms_key_ring_id]
}

run "gke_kms_ignored_when_existing_cluster_triggers_warning" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
    create_gke_kms_key                     = true
    create_kms_key_ring                    = true
  }

  expect_failures = [check.gke_kms_ignored_when_existing]

  assert {
    condition = (
      length(google_kms_key_ring.n8n) == 0 &&
      length(google_kms_crypto_key.gke) == 0 &&
      length(google_kms_crypto_key_iam_member.gke) == 0
    )
    error_message = "Ignored GKE CMEK inputs must not create a key ring, key, or IAM binding for an existing cluster."
  }
}

# ── Secret Manager CSI driver add-on ───────────────────────────────────────────

run "gke_secret_manager_addon_renders_when_enabled" {
  command = plan

  variables {
    gke_secret_manager_addon_enabled = true
  }

  assert {
    condition = (
      length(google_container_cluster.n8n[0].secret_manager_config) == 1 &&
      google_container_cluster.n8n[0].secret_manager_config[0].enabled == true
    )
    error_message = "secret_manager_config must render enabled = true when gke_secret_manager_addon_enabled is true."
  }
}

run "gke_secret_manager_addon_ignored_when_existing_cluster_triggers_warning" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
    gke_secret_manager_addon_enabled       = true
  }

  expect_failures = [check.gke_tuning_ignored_when_existing]
}
