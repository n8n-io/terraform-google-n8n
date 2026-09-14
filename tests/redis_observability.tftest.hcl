# Plan-time tests for section 16 (redis-observability): the opt-in Redis
# exporter (observability.tf) - default absence, independence from
# n8n_metrics_enabled/worker KEDA, the shared Redis connection/queue-key/TLS
# contract with n8n and KEDA, and pod hardening.

mock_provider "google" {}
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

# ── Disabled by default ───────────────────────────────────────────────────────

run "exporter_disabled_by_default" {
  command = plan

  assert {
    condition     = length(kubernetes_deployment_v1.redis_exporter) == 0
    error_message = "redis_exporter_enabled defaults to false; no exporter Deployment should be planned."
  }

  assert {
    condition     = length(kubernetes_service_v1.redis_exporter) == 0
    error_message = "redis_exporter_enabled defaults to false; no exporter Service should be planned."
  }

  assert {
    condition     = output.redis_exporter_service_name == null
    error_message = "redis_exporter_service_name output must be null when the exporter is disabled."
  }
}

# ── Enabled independently of n8n metrics and worker KEDA ─────────────────────

run "exporter_enabled_without_other_metrics_or_keda" {
  command = plan

  variables {
    redis_exporter_enabled  = true
    n8n_metrics_enabled     = false
    n8n_worker_keda_enabled = false
  }

  assert {
    condition     = length(kubernetes_deployment_v1.redis_exporter) == 1
    error_message = "redis_exporter_enabled = true must create the exporter Deployment."
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].replicas == "1"
    error_message = "The exporter must run exactly one replica."
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].strategy[0].type == "Recreate"
    error_message = "The exporter must use the Recreate rollout strategy."
  }

  assert {
    condition     = length(kubernetes_service_v1.redis_exporter) == 1
    error_message = "redis_exporter_enabled = true must create the metrics Service."
  }

  assert {
    condition     = kubernetes_service_v1.redis_exporter[0].spec[0].type == "ClusterIP"
    error_message = "The exporter Service must be ClusterIP; no public ingress route."
  }

  assert {
    condition     = output.redis_exporter_service_name == "redis-exporter"
    error_message = "redis_exporter_service_name output must resolve to the created Service's name."
  }
}

# ── Managed Memorystore: default (no TLS/AUTH) endpoint and queue keys ───────

run "exporter_managed_redis_defaults" {
  command = plan

  variables {
    redis_exporter_enabled = true
  }

  # google_redis_instance.n8n[0].host/port are unknown under the mock
  # provider at plan time (see AGENTS.md's known mock-provider limitations),
  # so REDIS_ADDR's full interpolated value cannot be asserted here; only
  # that the env name is present. The scheme/host/port formula itself is
  # exercised against known values in the external-Redis runs below.
  assert {
    condition = anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      e.name == "REDIS_ADDR"
    ])
    error_message = "REDIS_ADDR must be set on the exporter container."
  }

  assert {
    condition = anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      e.name == "REDIS_EXPORTER_CHECK_SINGLE_KEYS" && e.value == "bull:jobs:wait,bull:jobs:active"
    ])
    error_message = "REDIS_EXPORTER_CHECK_SINGLE_KEYS must use the default bull-prefixed waiting/active queue keys."
  }

  assert {
    condition     = length(kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].volume) == 0
    error_message = "No CA volume should be mounted when Redis TLS is disabled."
  }
}

# ── Managed Memorystore transit encryption: exporter trusts the service CA ──

run "exporter_managed_redis_tls_mounts_service_ca" {
  command = plan

  variables {
    redis_exporter_enabled           = true
    redis_transit_encryption_enabled = true
    n8n_redis_timeout_threshold_ms   = 30000
  }

  # google_redis_instance.n8n[0].host/port are unknown under the mock
  # provider at plan time; only the CA-trust wiring below is asserted here,
  # the rediss:// scheme itself is exercised against a known host in the
  # external-Redis TLS run.
  assert {
    condition = anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      e.name == "REDIS_ADDR"
    ])
    error_message = "REDIS_ADDR must be set on the exporter container."
  }

  assert {
    condition = anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      e.name == "REDIS_EXPORTER_TLS_CA_CERT_FILE"
    ])
    error_message = "REDIS_EXPORTER_TLS_CA_CERT_FILE must be set when managed Memorystore transit encryption is enabled."
  }

  assert {
    condition     = length(kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].volume) == 1
    error_message = "The managed service CA Secret must be mounted as a volume."
  }

  assert {
    condition = !anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      contains(["REDIS_EXPORTER_SKIP_TLS_VERIFICATION", "REDIS_EXPORTER_TLS_SKIP_VERIFY"], e.name)
    ])
    error_message = "The exporter must never disable TLS verification."
  }
}

# ── External Redis with TLS, ACL username, password Secret, custom prefix ──

run "exporter_external_redis_with_credentials_and_custom_prefix" {
  command = plan

  variables {
    redis_exporter_enabled = true
    create_redis_instance  = false
    redis_host             = "10.9.8.8"
    redis_port             = 6380
    redis_tls_enabled      = true
    redis_username         = "n8n"
    redis_password_secret_ref = {
      name = "external-redis-credentials"
      key  = "redis-password"
    }
    redis_key_prefix = "custom"
  }

  assert {
    condition = anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      e.name == "REDIS_ADDR" && e.value == "rediss://10.9.8.8:6380"
    ])
    error_message = "REDIS_ADDR must use the external host/port and TLS scheme."
  }

  assert {
    condition = anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      e.name == "REDIS_USER" && e.value == "n8n"
    ])
    error_message = "REDIS_USER must be set to the external ACL username."
  }

  assert {
    condition = anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      e.name == "REDIS_EXPORTER_CHECK_SINGLE_KEYS" && e.value == "custom:jobs:wait,custom:jobs:active"
    ])
    error_message = "REDIS_EXPORTER_CHECK_SINGLE_KEYS must use the custom redis_key_prefix."
  }

  assert {
    condition = alltrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      e.name != "REDIS_PASSWORD" || (
        length(e.value_from) == 1 &&
        e.value_from[0].secret_key_ref[0].name == "external-redis-credentials" &&
        e.value_from[0].secret_key_ref[0].key == "redis-password" &&
        e.value == null
      )
    ])
    error_message = "REDIS_PASSWORD must come from the referenced external Secret, never an inline literal."
  }

  assert {
    condition     = length(kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].volume) == 0
    error_message = "External Redis must not mount the module-managed Memorystore CA."
  }
}

# ── External Redis without any credentials: plaintext, no password/CA env ──

run "exporter_external_redis_unauthenticated_plaintext" {
  command = plan

  variables {
    redis_exporter_enabled = true
    create_redis_instance  = false
    redis_host             = "10.9.8.8"
  }

  assert {
    condition = anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      e.name == "REDIS_ADDR" && e.value == "redis://10.9.8.8:6379"
    ])
    error_message = "REDIS_ADDR must use the non-TLS scheme for plaintext external Redis."
  }

  assert {
    condition = !anytrue([
      for e in kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].env :
      contains(["REDIS_PASSWORD", "REDIS_USER", "REDIS_EXPORTER_TLS_CA_CERT_FILE"], e.name)
    ])
    error_message = "No password, username, or CA env should be set when Redis has neither credentials nor TLS."
  }
}

# ── Hardened pod contract ─────────────────────────────────────────────────────

run "exporter_hardened_pod_contract" {
  command = plan

  variables {
    redis_exporter_enabled = true
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].automount_service_account_token == false
    error_message = "The exporter pod must not automount a Kubernetes API token."
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].security_context[0].allow_privilege_escalation == false
    error_message = "The exporter must not allow privilege escalation."
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].security_context[0].read_only_root_filesystem == true
    error_message = "The exporter must run with a read-only root filesystem."
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].security_context[0].run_as_non_root == true
    error_message = "The exporter must run as non-root."
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].security_context[0].capabilities[0].drop[0] == "ALL"
    error_message = "The exporter must drop all Linux capabilities."
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].resources[0].requests["cpu"] == "10m"
    error_message = "The exporter must request 10m CPU."
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].resources[0].requests["memory"] == "32Mi"
    error_message = "The exporter must request 32Mi memory."
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].resources[0].limits["memory"] == "64Mi"
    error_message = "The exporter must limit memory to 64Mi."
  }

  assert {
    condition     = length(kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].liveness_probe) == 1
    error_message = "The exporter must have a liveness probe."
  }

  assert {
    condition     = length(kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].spec[0].container[0].readiness_probe) == 1
    error_message = "The exporter must have a readiness probe."
  }
}

# ── Image must be pinned (no unpinned floating tag) ──────────────────────────

run "exporter_image_requires_explicit_tag" {
  command = plan

  variables {
    redis_exporter_image = "oliver006/redis_exporter"
  }

  expect_failures = [var.redis_exporter_image]
}
