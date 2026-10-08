# Plan-time tests for the section 1 ownership-interface foundation: the static
# ownership switches, customer-managed reference variables, opposite-path
# diagnostics, and ownership-neutral effective outputs added across
# variables.tf, variables_gcp.tf, checks.tf, locals.tf, and outputs.tf.
#
# Resource-level `count` gating for each layer (network, GKE, Redis, GCS, ...)
# lands in its own later task section; these tests exercise the variable
# contract and the effective-output plumbing this section is responsible for.

# mock_data "google_container_cluster" satisfies the existing-GKE data
# lookup's lifecycle postconditions (VPC-native, Workload Identity enabled,
# same-project pool) so runs that set create_gke = false plan cleanly here;
# tests/gke_ownership.tftest.hcl exercises the postconditions themselves.
mock_provider "google" {
  mock_data "google_container_cluster" {
    defaults = {
      endpoint                 = "10.0.0.2"
      networking_mode          = "VPC_NATIVE"
      master_auth              = [{ client_certificate = "", client_certificate_config = [], client_key = "", cluster_ca_certificate = "ZmFrZS1jYQ==" }]
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

# ── Defaults stay fully managed ───────────────────────────────────────────────

run "defaults_are_fully_managed" {
  command = plan

  assert {
    condition = (
      var.create_network &&
      var.create_gke &&
      var.create_postgres_instance &&
      var.create_redis_instance &&
      var.create_gcs_bucket &&
      var.create_namespace &&
      var.create_ingress &&
      var.create_psa &&
      var.n8n_main_hpa_enabled &&
      var.n8n_webhook_hpa_enabled &&
      var.n8n_worker_keda_enabled
    )
    error_message = "Every ownership switch must default to true, preserving the current fully module-managed deployment."
  }
}

# Computed attributes (network id, cluster name, redis host, bucket name) are
# unknown at plan time under the mock providers, so these effective outputs
# can only be asserted as "known after apply" (non-null-typed) here; the
# gke_cluster_name assertion uses a plan-known attribute instead. A real
# `terraform plan` from an example root confirms the values themselves alias
# the module-managed resource.
run "defaults_produce_effective_outputs_from_managed_resources" {
  command = plan

  assert {
    condition     = google_container_cluster.n8n[0].name == "test-n8n"
    error_message = "gke_cluster_name should be derived from the module-managed cluster name by default."
  }

  assert {
    condition     = output.gke_cluster_name == "test-n8n"
    error_message = "gke_cluster_name output should equal the module-managed cluster name by default."
  }

  assert {
    condition     = output.workload_identity_pool == "test-project.svc.id.goog"
    error_message = "workload_identity_pool should default to <project_id>.svc.id.goog."
  }
}

# ── Nullability on the customer-managed path ─────────────────────────────────
# The existing-GKE data lookup itself (mocked cluster values, compatibility
# postconditions) is exercised in tests/gke_ownership.tftest.hcl; this file
# only asserts that gke_cluster_name still resolves to the supplied reference.

run "existing_gke_cluster_name_resolves_to_reference" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
  }

  assert {
    condition     = output.gke_cluster_name == "shared-cluster"
    error_message = "gke_cluster_name should resolve to existing_gke_cluster_name on the customer-managed path."
  }
}

run "existing_postgres_effective_outputs_are_null" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    n8n_database_password    = "external-db-password"
  }

  assert {
    condition     = output.postgres_private_ip == null
    error_message = "postgres_private_ip must be null when create_postgres_instance = false."
  }

  assert {
    condition     = output.postgres_connection_name == null
    error_message = "postgres_connection_name must be null when create_postgres_instance = false."
  }
}

# ── Selected-path missing references fail validation ─────────────────────────

run "existing_network_missing_references_fails_validation" {
  command = plan

  variables {
    create_network = false
    # existing_network_name, existing_subnetwork_name, existing_pods_range_name,
    # and existing_services_range_name intentionally unset.
  }

  expect_failures = [
    var.existing_network_name,
    var.existing_subnetwork_name,
    var.existing_pods_range_name,
    var.existing_services_range_name,
  ]
}

run "existing_gke_missing_attestation_fails_validation" {
  command = plan

  variables {
    create_gke                = false
    existing_gke_cluster_name = "shared-cluster"
    # existing_gke_prerequisites_attestation intentionally left false
  }

  expect_failures = [var.existing_gke_prerequisites_attestation]
}

run "existing_gke_missing_cluster_name_fails_validation" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_prerequisites_attestation = true
    # existing_gke_cluster_name intentionally unset
  }

  expect_failures = [var.existing_gke_cluster_name]
}

run "existing_redis_missing_host_fails_validation" {
  command = plan

  variables {
    create_redis_instance = false
    # redis_host intentionally unset
  }

  expect_failures = [var.redis_host]
}

run "existing_gcs_bucket_missing_name_fails_validation" {
  command = plan

  variables {
    create_gcs_bucket = false
    # existing_gcs_bucket_name intentionally unset
  }

  expect_failures = [var.existing_gcs_bucket_name]
}

run "existing_psa_without_attestation_fails_validation" {
  command = plan

  variables {
    create_psa = false
    # existing_psa_prerequisites_attestation intentionally left false, while
    # create_postgres_instance and create_redis_instance both default true.
  }

  expect_failures = [var.existing_psa_prerequisites_attestation]
}

# ── Complete customer-managed references plan cleanly ────────────────────────

run "fully_customer_managed_data_plane_plans_cleanly" {
  command = plan

  variables {
    create_postgres_instance = false
    n8n_database_host        = "10.9.8.7"
    n8n_database_password    = "external-db-password"

    create_redis_instance = false
    redis_host            = "10.9.8.8"
    redis_port            = 6380
    redis_tls_enabled     = true
    redis_username        = "n8n"
    redis_password        = "external-redis-password"

    create_gcs_bucket        = false
    existing_gcs_bucket_name = "existing-n8n-bucket"
  }

  assert {
    condition     = output.redis_host == "10.9.8.8"
    error_message = "redis_host output should track the external redis_host variable."
  }

  assert {
    condition     = output.redis_port == 6380
    error_message = "redis_port output should track the external redis_port variable."
  }

  assert {
    condition     = output.redis_tls_enabled == true
    error_message = "redis_tls_enabled output should track the external redis_tls_enabled variable."
  }

  assert {
    condition     = output.gcs_bucket_name == "existing-n8n-bucket"
    error_message = "gcs_bucket_name output should track existing_gcs_bucket_name."
  }
}

# ── Full customer-managed composition omits every selected ownership layer ───

run "fully_customer_managed_stack_creates_no_owned_infrastructure" {
  command = plan

  variables {
    create_network               = false
    existing_network_name        = "existing-vpc"
    existing_subnetwork_name     = "existing-subnet"
    existing_pods_range_name     = "existing-pods"
    existing_services_range_name = "existing-services"
    create_psa                   = false

    create_gke                             = false
    existing_gke_cluster_name              = "existing-cluster"
    existing_gke_prerequisites_attestation = true

    create_postgres_instance = false
    n8n_database_host        = "postgres.external.example.com"
    n8n_database_password_secret_ref = {
      name = "external-postgres-password"
    }

    create_redis_instance = false
    redis_host            = "redis.external.example.com"
    redis_password_secret_ref = {
      name = "external-redis-password"
    }

    create_gcs_bucket              = false
    existing_gcs_bucket_name       = "external-n8n-bucket"
    gcs_hmac_service_account_email = "byo-hmac@test-project.iam.gserviceaccount.com"
    gcs_hmac_access_id             = "GOOG1EXAMPLEACCESSID"
    gcs_hmac_secret_name           = "external-gcs-hmac-secret"

    create_namespace   = false
    n8n_kube_namespace = "existing-n8n"
    create_ingress     = false

    n8n_main_hpa_enabled    = false
    n8n_webhook_hpa_enabled = false
    n8n_worker_keda_enabled = false

    install_keda                     = false
    create_pd_balanced_storage_class = false
  }

  assert {
    condition = (
      length(google_compute_network.n8n) == 0 &&
      length(google_compute_subnetwork.n8n) == 0 &&
      length(google_compute_router.n8n) == 0 &&
      length(google_compute_router_nat.n8n) == 0 &&
      length(google_compute_global_address.psa) == 0 &&
      length(google_service_networking_connection.psa) == 0
    )
    error_message = "The fully customer-managed stack must create no network or PSA resources."
  }

  assert {
    condition = (
      length(google_container_cluster.n8n) == 0 &&
      length(google_container_node_pool.n8n) == 0 &&
      length(google_service_account.nodes) == 0 &&
      length(google_project_iam_member.nodes) == 0
    )
    error_message = "The fully customer-managed stack must create no GKE or node-identity resources."
  }

  assert {
    condition = (
      length(google_sql_database_instance.n8n) == 0 &&
      length(random_password.db_password) == 0 &&
      length(google_sql_database.n8n) == 0 &&
      length(google_sql_user.n8n) == 0 &&
      length(google_project_iam_member.n8n_cloudsql_client) == 0 &&
      length(google_redis_instance.n8n) == 0 &&
      length(google_storage_bucket.n8n) == 0
    )
    error_message = "The fully customer-managed stack must create no Cloud SQL, Memorystore, or GCS data-service resources."
  }

  assert {
    condition = (
      length(google_kms_key_ring.n8n) == 0 &&
      length(google_kms_crypto_key.postgres) == 0 &&
      length(google_kms_crypto_key.redis) == 0 &&
      length(google_kms_crypto_key.gcs) == 0
    )
    error_message = "The fully customer-managed stack must create no Cloud KMS resources."
  }

  assert {
    condition = (
      length(kubernetes_namespace.n8n) == 0 &&
      length(kubernetes_secret.n8n_db) == 0 &&
      length(kubernetes_secret.n8n_redis) == 0 &&
      length(kubernetes_secret.n8n_s3) == 0 &&
      length(kubernetes_secret.redis_auth) == 0
    )
    error_message = "The fully customer-managed stack must create no selected namespace or credential Secret resources."
  }

  assert {
    condition = (
      length(google_compute_global_address.lb) == 0 &&
      length(google_dns_record_set.n8n) == 0 &&
      length(kubernetes_ingress_v1.n8n) == 0 &&
      length(kubectl_manifest.backendconfig) == 0 &&
      length(kubectl_manifest.frontendconfig) == 0 &&
      length(kubectl_manifest.managed_certificate) == 0 &&
      length(google_compute_ssl_certificate.n8n) == 0 &&
      length(time_sleep.wait_for_lb_cleanup) == 0
    )
    error_message = "The fully customer-managed stack must create no ingress, DNS, TLS, or load-balancer resources."
  }

  assert {
    condition = (
      length(kubernetes_horizontal_pod_autoscaler_v2.n8n_webhook) == 0 &&
      length(kubectl_manifest.redis_trigger_auth) == 0 &&
      module.controllers.keda_installed == false &&
      module.controllers.pd_balanced_storage_class_name == null
    )
    error_message = "The fully customer-managed stack must create no application scaler or controller resources."
  }
}

# ── Opposite-path input diagnostics (ignored-input warnings) ─────────────────
# `terraform test` treats a `check` block's warning as a failure, so
# `expect_failures = [check.<name>]` is how a passing test proves the warning
# fired. See tests/defaults.tftest.hcl for the same pattern applied to the
# pre-existing OpenTelemetry and log-streaming check blocks.

run "network_tuning_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_network               = false
    existing_network_name        = "shared-vpc"
    existing_subnetwork_name     = "shared-subnet"
    existing_pods_range_name     = "shared-pods"
    existing_services_range_name = "shared-services"
    subnet_cidr                  = "10.99.0.0/20"
  }

  expect_failures = [check.network_tuning_ignored_when_existing]
}

run "gke_tuning_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
    gke_node_type                          = "e2-standard-8"
  }

  expect_failures = [check.gke_tuning_ignored_when_existing]
}

run "gke_security_group_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
    gke_security_group                     = "gke-security-groups@example.com"
  }

  expect_failures = [check.gke_tuning_ignored_when_existing]
}

run "gke_private_endpoint_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
    gke_enable_private_endpoint            = true
  }

  # No authorized networks: gke_enable_private_endpoint's validations apply
  # only when create_gke = true, so an existing cluster gets the warning
  # below instead of a validation error.
  expect_failures = [check.gke_tuning_ignored_when_existing]

  assert {
    condition     = !strcontains(output.kubectl_config_command, "--internal-ip")
    error_message = "kubectl_config_command must not add --internal-ip for an existing cluster; gke_enable_private_endpoint is ignored when create_gke = false."
  }
}

run "gke_private_endpoint_with_public_nodes_ignored_when_existing" {
  command = plan

  variables {
    create_gke                             = false
    existing_gke_cluster_name              = "shared-cluster"
    existing_gke_prerequisites_attestation = true
    gke_enable_private_endpoint            = true
    gke_enable_private_nodes               = false
  }

  expect_failures = [check.gke_tuning_ignored_when_existing]
}

run "redis_tuning_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_redis_instance = false
    redis_host            = "10.9.8.8"
    redis_tier            = "STANDARD_HA"
  }

  expect_failures = [check.redis_tuning_ignored_when_existing]
}

run "redis_maxmemory_policy_ignored_when_external_triggers_warning" {
  command = plan

  variables {
    create_redis_instance  = false
    redis_host             = "10.9.8.8"
    redis_maxmemory_policy = "allkeys-lru"
  }

  expect_failures = [check.redis_tuning_ignored_when_existing]
}

# The LFU-needs-Redis-4.0 validation is scoped to the managed instance: on the
# external path both inputs are ignored, so the combination only warns.
run "redis_lfu_on_redis_3_2_only_warns_when_external" {
  command = plan

  variables {
    create_redis_instance  = false
    redis_host             = "10.9.8.8"
    redis_version          = "REDIS_3_2"
    redis_maxmemory_policy = "allkeys-lfu"
  }

  expect_failures = [check.redis_tuning_ignored_when_existing]
}

run "gcs_tuning_ignored_when_existing_triggers_warning" {
  command = plan

  variables {
    create_gcs_bucket        = false
    existing_gcs_bucket_name = "existing-n8n-bucket"
    gcs_force_destroy        = true
  }

  expect_failures = [check.gcs_tuning_ignored_when_existing]
}

run "network_tuning_matches_defaults_plans_cleanly" {
  command = plan

  variables {
    create_network               = false
    existing_network_name        = "shared-vpc"
    existing_subnetwork_name     = "shared-subnet"
    existing_pods_range_name     = "shared-pods"
    existing_services_range_name = "shared-services"
  }

  assert {
    condition     = var.create_network == false
    error_message = "create_network should accept false when every existing-network reference is supplied."
  }
}

# ── Exact-version validators ──────────────────────────────────────────────────

run "n8n_chart_version_rejects_floating_tag" {
  command = plan

  variables {
    n8n_chart_version = "latest"
  }

  expect_failures = [var.n8n_chart_version]
}

run "n8n_chart_version_rejects_version_range" {
  command = plan

  variables {
    n8n_chart_version = "~> 1.10"
  }

  expect_failures = [var.n8n_chart_version]
}

run "keda_chart_version_rejects_floating_tag" {
  command = plan

  variables {
    keda_chart_version = "latest"
  }

  expect_failures = [var.keda_chart_version]
}

run "chart_versions_accept_exact_semver" {
  command = plan

  variables {
    n8n_chart_version  = "1.11.0"
    keda_chart_version = "2.21.0"
  }

  assert {
    condition     = var.n8n_chart_version == "1.11.0" && var.keda_chart_version == "2.21.0"
    error_message = "Exact semantic versions must remain accepted."
  }
}

# ── Scaler ownership fixed-replica inputs ─────────────────────────────────────

run "scaler_ownership_defaults_enabled" {
  command = plan

  assert {
    condition = (
      var.n8n_main_hpa_enabled &&
      var.n8n_webhook_hpa_enabled &&
      var.n8n_worker_keda_enabled
    )
    error_message = "Every scaler ownership switch must default to true."
  }
}

run "scaler_ownership_accepts_disabled_with_fixed_replicas" {
  command = plan

  variables {
    n8n_main_hpa_enabled       = false
    n8n_main_fixed_replicas    = 3
    n8n_webhook_hpa_enabled    = false
    n8n_webhook_fixed_replicas = 4
    n8n_worker_keda_enabled    = false
    n8n_worker_fixed_replicas  = 5
  }

  assert {
    condition = (
      var.n8n_main_fixed_replicas == 3 &&
      var.n8n_webhook_fixed_replicas == 4 &&
      var.n8n_worker_fixed_replicas == 5
    )
    error_message = "Fixed replica counts must propagate when their scaler is disabled."
  }
}

# ── Service and route contract outputs ────────────────────────────────────────

run "service_and_route_outputs_are_stable" {
  command = plan

  assert {
    condition     = output.n8n_main_service_name == "n8n-main"
    error_message = "n8n_main_service_name must be the chart's fixed main service name."
  }

  assert {
    condition     = output.n8n_webhook_service_name == "n8n-webhook-processor"
    error_message = "n8n_webhook_service_name must be the chart's fixed webhook service name."
  }

  assert {
    condition     = output.n8n_service_port == 5678
    error_message = "n8n_service_port must be 5678."
  }

  assert {
    condition = toset(output.n8n_webhook_route_prefixes) == toset([
      "/webhook", "/webhook-waiting", "/form", "/form-waiting", "/mcp",
    ])
    error_message = "n8n_webhook_route_prefixes must include every documented webhook-family route."
  }
}
