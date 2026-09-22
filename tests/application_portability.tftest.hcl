# Plan-time tests for section 10: custom n8n and task-runner image
# repositories/tags/pull policy/pull Secrets, the n8n chart repository, a
# custom extensions path, execution-data storage mode, the floating-license
# shutdown default, and the n8n_extra_env reserved-name expansion that comes
# with them.
#
# config.extraEnv's actual rendered content lives inside helm_release.n8n.values
# (a JSON-encoded string, unknown at plan time under the mock provider because
# it depends on kubernetes_namespace - see AGENTS.md's known mock-provider
# limitations), so most of this is asserted at the variable-contract layer,
# mirroring the existing OpenTelemetry/log-streaming/External-Secrets test
# pattern. To verify the Helm values end-to-end: run `terraform plan` from
# examples/small/ with these variables set and inspect the helm_release.n8n
# plan output directly.

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

# ── n8n chart repository ──────────────────────────────────────────────────────

run "chart_repository_defaults_to_public_upstream" {
  command = plan

  assert {
    condition     = var.n8n_chart_repository == "oci://ghcr.io/n8n-io/n8n-helm-chart"
    error_message = "n8n_chart_repository should default to the public upstream OCI repository."
  }

  assert {
    condition     = helm_release.n8n.repository == "oci://ghcr.io/n8n-io/n8n-helm-chart"
    error_message = "helm_release.n8n.repository should use n8n_chart_repository."
  }
}

run "chart_repository_accepts_private_mirror" {
  command = plan

  variables {
    n8n_chart_repository = "https://charts.internal.example.com/n8n"
  }

  assert {
    condition     = helm_release.n8n.repository == "https://charts.internal.example.com/n8n"
    error_message = "helm_release.n8n.repository should use a supplied private mirror."
  }
}

run "chart_repository_rejects_invalid_scheme" {
  command = plan

  variables {
    n8n_chart_repository = "ftp://charts.internal.example.com/n8n"
  }

  expect_failures = [var.n8n_chart_repository]
}

# ── n8n application image ─────────────────────────────────────────────────────

run "image_repository_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_image_repository == null
    error_message = "n8n_image_repository should default to null so the chart's own repository applies."
  }
}

run "image_repository_accepts_bare_reference" {
  command = plan

  variables {
    n8n_image_repository = "us-docker.pkg.dev/test-project/n8n/n8n"
  }

  assert {
    condition     = var.n8n_image_repository == "us-docker.pkg.dev/test-project/n8n/n8n"
    error_message = "n8n_image_repository should accept a bare registry/repository reference."
  }
}

run "image_repository_rejects_scheme" {
  command = plan

  variables {
    n8n_image_repository = "https://us-docker.pkg.dev/test-project/n8n/n8n"
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_repository_rejects_embedded_tag" {
  command = plan

  variables {
    n8n_image_repository = "n8nio/n8n:1.2.3"
  }

  expect_failures = [var.n8n_image_repository]
}

run "image_pull_policy_accepts_valid_value" {
  command = plan

  variables {
    n8n_image_pull_policy = "Always"
  }

  assert {
    condition     = var.n8n_image_pull_policy == "Always"
    error_message = "n8n_image_pull_policy should accept Always."
  }
}

run "image_pull_policy_rejects_invalid_value" {
  command = plan

  variables {
    n8n_image_pull_policy = "Sometimes"
  }

  expect_failures = [var.n8n_image_pull_policy]
}

# ── Image pull Secrets and ServiceAccount ownership ───────────────────────────

run "image_pull_secrets_default_to_empty_and_chart_owns_service_account" {
  command = plan

  assert {
    condition     = length(var.n8n_image_pull_secrets) == 0
    error_message = "n8n_image_pull_secrets should default to an empty list."
  }

  assert {
    condition     = length(kubernetes_service_account_v1.n8n) == 0
    error_message = "No module-managed ServiceAccount should be created when n8n_image_pull_secrets is empty; the chart creates its own."
  }
}

run "image_pull_secrets_move_service_account_ownership_to_module" {
  command = plan

  variables {
    n8n_image_repository   = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_pull_secrets = ["ar-pull-creds"]
  }

  assert {
    condition     = length(kubernetes_service_account_v1.n8n) == 1
    error_message = "A module-managed ServiceAccount should be created when n8n_image_pull_secrets is non-empty."
  }

  assert {
    condition     = kubernetes_service_account_v1.n8n[0].metadata[0].name == "n8n-pull"
    error_message = "The module-managed ServiceAccount should use a name distinct from the chart's default (n8n) to avoid a collision on an already-applied stack."
  }
}

run "image_pull_secrets_rejects_invalid_name" {
  command = plan

  variables {
    n8n_image_repository   = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_pull_secrets = ["Invalid_Name"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "image_pull_secrets_rejects_duplicates" {
  command = plan

  variables {
    n8n_image_repository   = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_pull_secrets = ["ar-pull-creds", "ar-pull-creds"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "image_pull_secrets_rejects_overlong_label" {
  command = plan

  variables {
    n8n_image_repository   = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_pull_secrets = ["${join("", [for i in range(64) : "a"])}.pull-creds"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "image_pull_secrets_rejects_empty_label" {
  command = plan

  variables {
    n8n_image_repository   = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_pull_secrets = ["ar..pull-creds"]
  }

  expect_failures = [var.n8n_image_pull_secrets]
}

run "image_pull_secrets_accepts_max_length_label" {
  command = plan

  variables {
    n8n_image_repository   = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_pull_secrets = ["${join("", [for i in range(63) : "a"])}.pull-creds"]
  }

  assert {
    condition     = length(kubernetes_service_account_v1.n8n) == 1
    error_message = "A 63-character label is valid and must be accepted."
  }
}

run "image_pull_secrets_without_image_repository_triggers_check_warning" {
  command = plan

  variables {
    n8n_image_pull_secrets = ["ar-pull-creds"]
  }

  expect_failures = [check.image_pull_secrets_need_a_custom_image]
}

# ── Task runner image ─────────────────────────────────────────────────────────

run "task_runner_image_tag_and_repository_default_to_null" {
  command = plan

  assert {
    condition     = var.n8n_task_runner_image_tag == null && var.n8n_task_runner_image_repository == null
    error_message = "Task runner image repository/tag should default to null so the chart inherits from the app image's tag."
  }
}

run "task_runner_image_tag_accepts_concrete_version" {
  command = plan

  variables {
    n8n_task_runner_image_tag = "2.27.4"
  }

  assert {
    condition     = var.n8n_task_runner_image_tag == "2.27.4"
    error_message = "n8n_task_runner_image_tag should accept a concrete version string."
  }
}

run "task_runner_image_tag_set_without_task_runners_triggers_check_warning" {
  command = plan

  variables {
    n8n_task_runner_image_tag = "2.27.4"
    n8n_task_runners_enabled  = false
  }

  expect_failures = [check.task_runner_image_tag_requires_task_runners]
}

run "custom_image_without_matching_task_runner_tag_triggers_check_warning" {
  command = plan

  variables {
    n8n_image_repository = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_image_tag        = "2.27.4-mypackages"
  }

  expect_failures = [check.custom_image_tag_requires_task_runner_tag]
}

# ── Task runner execution timeout (section 12) ────────────────────────────────

run "task_runner_timeout_defaults_to_300" {
  command = plan

  assert {
    condition     = var.n8n_task_runner_timeout == 300
    error_message = "n8n_task_runner_timeout should default to 300 seconds."
  }
}

run "task_runner_timeout_and_request_timeout_accept_distinct_explicit_values" {
  command = plan

  variables {
    n8n_task_runner_timeout         = 120
    n8n_task_runner_request_timeout = 45
  }

  assert {
    condition     = var.n8n_task_runner_timeout == 120 && var.n8n_task_runner_request_timeout == 45
    error_message = "n8n_task_runner_timeout (execution) and n8n_task_runner_request_timeout (acceptance) should accept distinct explicit values independently."
  }
}

run "task_runner_timeout_rejects_zero" {
  command = plan

  variables {
    n8n_task_runner_timeout = 0
  }

  expect_failures = [var.n8n_task_runner_timeout]
}

run "task_runner_timeout_rejects_negative" {
  command = plan

  variables {
    n8n_task_runner_timeout = -1
  }

  expect_failures = [var.n8n_task_runner_timeout]
}

run "task_runner_timeout_rejects_fraction" {
  command = plan

  variables {
    n8n_task_runner_timeout = 60.5
  }

  expect_failures = [var.n8n_task_runner_timeout]
}

run "extra_env_rejects_task_runner_timeout_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_RUNNERS_TASK_TIMEOUT", value = "999" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# ── Task runner custom launcher configuration (section 12) ───────────────────

run "task_runner_custom_config_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_task_runner_custom_config == null
    error_message = "n8n_task_runner_custom_config should default to null so the chart's built-in launcher configuration applies."
  }
}

run "task_runner_custom_config_accepts_valid_reference" {
  command = plan

  variables {
    n8n_task_runner_custom_config = {
      config_map_name = "n8n-runner-launcher"
    }
  }

  assert {
    condition     = var.n8n_task_runner_custom_config.config_map_name == "n8n-runner-launcher"
    error_message = "n8n_task_runner_custom_config.config_map_name should accept a valid ConfigMap name."
  }

  assert {
    condition     = var.n8n_task_runner_custom_config.config_map_key == "n8n-task-runners.json"
    error_message = "n8n_task_runner_custom_config.config_map_key should default to n8n-task-runners.json."
  }
}

run "task_runner_custom_config_accepts_custom_key" {
  command = plan

  variables {
    n8n_task_runner_custom_config = {
      config_map_name = "n8n-runner-launcher"
      config_map_key  = "launcher-config.json"
    }
  }

  assert {
    condition     = var.n8n_task_runner_custom_config.config_map_key == "launcher-config.json"
    error_message = "n8n_task_runner_custom_config.config_map_key should accept an explicit key."
  }
}

run "task_runner_custom_config_rejects_invalid_config_map_name" {
  command = plan

  variables {
    n8n_task_runner_custom_config = {
      config_map_name = "Invalid_Name"
    }
  }

  expect_failures = [var.n8n_task_runner_custom_config]
}

run "task_runner_custom_config_rejects_invalid_config_map_key" {
  command = plan

  variables {
    n8n_task_runner_custom_config = {
      config_map_name = "n8n-runner-launcher"
      config_map_key  = "invalid key!"
    }
  }

  expect_failures = [var.n8n_task_runner_custom_config]
}

run "task_runner_custom_config_requires_task_runners_enabled" {
  command = plan

  variables {
    n8n_task_runners_enabled = false
    n8n_task_runner_custom_config = {
      config_map_name = "n8n-runner-launcher"
    }
  }

  expect_failures = [var.n8n_task_runner_custom_config]
}

# ── Pod DNS (n8n_dns_config, section 13) ───────────────────────────────────────
# Plan-time variable-contract assertions only, per AGENTS.md's documented mock
# provider limitation: helm_release.values is unknown at plan time, so the
# rendered dnsConfig cannot be asserted on here.

run "dns_config_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_dns_config == null
    error_message = "n8n_dns_config must default to null so Kubernetes' own DNS defaults apply unless a caller opts in."
  }

  assert {
    condition     = local.n8n_dns_config == null
    error_message = "local.n8n_dns_config must resolve to null when the variable is unset, so the dnsConfig key is omitted entirely rather than rendering an empty map."
  }
}

run "dns_config_empty_object_resolves_to_null" {
  command = plan

  variables {
    n8n_dns_config = {}
  }

  assert {
    condition     = local.n8n_dns_config == null
    error_message = "local.n8n_dns_config must collapse an empty object (all attributes unset) to null, so the dnsConfig key is omitted from the Helm values entirely rather than rendering `dnsConfig: {}`."
  }
}

run "dns_config_accepts_an_ndots_override" {
  command = plan

  variables {
    n8n_dns_config = {
      options = [{ name = "ndots", value = "1" }]
    }
  }

  assert {
    condition     = local.n8n_dns_config.options[0].name == "ndots" && local.n8n_dns_config.options[0].value == "1"
    error_message = "local.n8n_dns_config must carry through a valid ndots option unchanged."
  }

  assert {
    condition     = !contains(keys(local.n8n_dns_config), "nameservers") && !contains(keys(local.n8n_dns_config), "searches")
    error_message = "local.n8n_dns_config must omit nameservers/searches keys entirely when unset, not render them as null: the chart's bare toYaml would emit `nameservers: null`, which the Kubernetes API server rejects."
  }
}

run "dns_config_accepts_ipv4_and_ipv6_nameservers" {
  command = plan

  variables {
    n8n_dns_config = {
      nameservers = ["10.0.0.2", "fd00:10::a"]
    }
  }

  assert {
    condition     = length(local.n8n_dns_config.nameservers) == 2
    error_message = "local.n8n_dns_config must carry through valid IPv4 and IPv6 nameservers unchanged."
  }
}

run "dns_config_rejects_a_non_ip_nameserver" {
  command = plan

  variables {
    n8n_dns_config = {
      nameservers = ["dns.example.com"]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_a_fourth_nameserver" {
  command = plan

  variables {
    n8n_dns_config = {
      nameservers = ["10.0.0.2", "10.0.0.3", "10.0.0.4", "10.0.0.5"]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_accepts_valid_search_domains" {
  command = plan

  variables {
    n8n_dns_config = {
      searches = ["n8n.svc.cluster.local", "svc.cluster.local", "example.com"]
    }
  }

  assert {
    condition     = length(local.n8n_dns_config.searches) == 3
    error_message = "local.n8n_dns_config must carry through a valid searches list unchanged."
  }
}

run "dns_config_rejects_more_than_thirty_two_search_domains" {
  command = plan

  variables {
    n8n_dns_config = {
      searches = [for i in range(33) : "search-${i}.example.com"]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_an_oversized_search_list" {
  command = plan

  variables {
    # 30 entries of ~241 valid characters each joins to roughly 7,200, well past
    # the 2048-character ceiling, while staying under the 32-entry limit and the
    # 253-character per-entry limit so this run pins the joined-length branch
    # rather than the count or syntax branches.
    n8n_dns_config = {
      searches = [for i in range(30) : "${i}.${join(".", [for j in range(24) : "abcdefghi"])}"]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_a_malformed_search_domain" {
  command = plan

  variables {
    n8n_dns_config = {
      searches = ["Example.COM"]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_relaxed_only_search_shapes" {
  command = plan

  variables {
    # This module validates to the stricter grammar every supported GKE
    # release admits at pod-spec admission, not the relaxed rules
    # (RelaxedDNSSearchValidation) that only reached GA in Kubernetes 1.34: a
    # bare "." and an underscore-containing domain must both fail here even
    # though a 1.34+ cluster's API server would itself accept them.
    n8n_dns_config = {
      searches = [".", "_msdcs.corp.example.com"]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_duplicate_option_names" {
  command = plan

  variables {
    n8n_dns_config = {
      options = [
        { name = "ndots", value = "1" },
        { name = "ndots", value = "2" },
      ]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_a_non_numeric_ndots_value" {
  command = plan

  variables {
    n8n_dns_config = {
      options = [{ name = "ndots", value = "many" }]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_an_out_of_range_ndots_value" {
  command = plan

  variables {
    n8n_dns_config = {
      options = [{ name = "ndots", value = "16" }]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_ndots_without_a_value" {
  command = plan

  variables {
    n8n_dns_config = {
      options = [{ name = "ndots" }]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

run "dns_config_rejects_a_fractional_ndots_value" {
  command = plan

  variables {
    n8n_dns_config = {
      options = [{ name = "ndots", value = "1.5" }]
    }
  }

  expect_failures = [var.n8n_dns_config]
}

# ── V8 heap ceiling (n8n_node_max_old_space_size_mb, section 14) ─────────────

run "node_max_old_space_size_mb_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_node_max_old_space_size_mb == null
    error_message = "n8n_node_max_old_space_size_mb should default to null so Node's own heap heuristic applies."
  }
}

run "node_max_old_space_size_mb_accepts_explicit_value" {
  command = plan

  variables {
    n8n_node_max_old_space_size_mb = 512
  }

  assert {
    condition     = var.n8n_node_max_old_space_size_mb == 512
    error_message = "n8n_node_max_old_space_size_mb should accept an explicit whole-MiB value."
  }
}

run "node_max_old_space_size_mb_rejects_below_minimum" {
  command = plan

  variables {
    n8n_node_max_old_space_size_mb = 255
  }

  expect_failures = [var.n8n_node_max_old_space_size_mb]
}

run "node_max_old_space_size_mb_rejects_fraction" {
  command = plan

  variables {
    n8n_node_max_old_space_size_mb = 256.5
  }

  expect_failures = [var.n8n_node_max_old_space_size_mb]
}

run "node_max_old_space_size_mb_null_leaves_existing_node_options_escape_hatch_accepted" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "NODE_OPTIONS", value = "--max-old-space-size=768" },
    ]
  }

  assert {
    condition     = length(var.n8n_extra_env) == 1
    error_message = "NODE_OPTIONS set through n8n_extra_env should remain accepted while n8n_node_max_old_space_size_mb is null."
  }
}

run "node_max_old_space_size_mb_rejects_conflicting_extra_env_node_options" {
  command = plan

  variables {
    n8n_node_max_old_space_size_mb = 512
    n8n_extra_env = [
      { name = "NODE_OPTIONS", value = "--max-old-space-size=999" },
    ]
  }

  expect_failures = [var.n8n_node_max_old_space_size_mb]
}

# ── Community registry and security-related runtime controls (section 15) ───

run "community_packages_registry_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_community_packages_registry == null
    error_message = "n8n_community_packages_registry should default to null so n8n's own registry default applies."
  }
}

run "community_packages_registry_accepts_valid_https_url" {
  command = plan

  variables {
    n8n_community_packages_registry = "https://registry.internal.example.com/npm"
  }

  assert {
    condition     = var.n8n_community_packages_registry == "https://registry.internal.example.com/npm"
    error_message = "n8n_community_packages_registry should accept a valid HTTPS URL."
  }
}

run "community_packages_registry_rejects_blank" {
  command = plan

  variables {
    n8n_community_packages_registry = ""
  }

  expect_failures = [var.n8n_community_packages_registry]
}

run "community_packages_registry_rejects_non_https_scheme" {
  command = plan

  variables {
    n8n_community_packages_registry = "http://registry.internal.example.com/npm"
  }

  expect_failures = [var.n8n_community_packages_registry]
}

run "community_packages_registry_rejects_embedded_credentials" {
  command = plan

  variables {
    n8n_community_packages_registry = "https://user:pass@registry.internal.example.com/npm"
  }

  expect_failures = [var.n8n_community_packages_registry]
}

run "unverified_packages_enabled_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_unverified_packages_enabled == null
    error_message = "n8n_unverified_packages_enabled should default to null so n8n's own upstream default applies."
  }
}

run "unverified_packages_enabled_accepts_explicit_false" {
  command = plan

  variables {
    n8n_unverified_packages_enabled = false
  }

  assert {
    condition     = var.n8n_unverified_packages_enabled == false
    error_message = "n8n_unverified_packages_enabled should accept and preserve an explicit false, distinct from the null default."
  }
}

run "compression_limits_default_to_null" {
  command = plan

  assert {
    condition     = var.n8n_compression_max_decompressed_size_bytes == null && var.n8n_compression_max_zip_entries == null
    error_message = "Compression limits should default to null so n8n's own upstream defaults apply."
  }
}

run "compression_limits_accept_explicit_values" {
  command = plan

  variables {
    n8n_compression_max_decompressed_size_bytes = 1073741824
    n8n_compression_max_zip_entries             = 10000
  }

  assert {
    condition     = var.n8n_compression_max_decompressed_size_bytes == 1073741824 && var.n8n_compression_max_zip_entries == 10000
    error_message = "Compression limits should accept explicit positive whole values."
  }
}

run "compression_max_decompressed_size_bytes_rejects_zero" {
  command = plan

  variables {
    n8n_compression_max_decompressed_size_bytes = 0
  }

  expect_failures = [var.n8n_compression_max_decompressed_size_bytes]
}

run "compression_max_decompressed_size_bytes_rejects_fraction" {
  command = plan

  variables {
    n8n_compression_max_decompressed_size_bytes = 100.5
  }

  expect_failures = [var.n8n_compression_max_decompressed_size_bytes]
}

run "compression_max_zip_entries_rejects_negative" {
  command = plan

  variables {
    n8n_compression_max_zip_entries = -1
  }

  expect_failures = [var.n8n_compression_max_zip_entries]
}

# ── Custom extensions path ────────────────────────────────────────────────────

run "custom_extensions_path_defaults_to_null" {
  command = plan

  assert {
    condition     = var.n8n_custom_extensions_path == null
    error_message = "n8n_custom_extensions_path should default to null so N8N_CUSTOM_EXTENSIONS is omitted."
  }
}

run "custom_extensions_path_accepts_absolute_path" {
  command = plan

  variables {
    n8n_image_repository       = "us-docker.pkg.dev/test-project/n8n/n8n"
    n8n_custom_extensions_path = "/opt/n8n-nodes"
  }

  assert {
    condition     = var.n8n_custom_extensions_path == "/opt/n8n-nodes"
    error_message = "n8n_custom_extensions_path should accept an absolute path."
  }
}

run "custom_extensions_path_rejects_relative_path" {
  command = plan

  variables {
    n8n_custom_extensions_path = "opt/n8n-nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_semicolon" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n;nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_trailing_slash" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes/"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_double_slash" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt//n8n-nodes"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_rejects_home_node_n8n" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/home/node/.n8n/extra"
  }

  expect_failures = [var.n8n_custom_extensions_path]
}

run "custom_extensions_path_without_image_repository_triggers_check_warning" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes"
  }

  expect_failures = [check.custom_extensions_path_requires_a_custom_image]
}

# ── Execution data storage mode ───────────────────────────────────────────────

run "execution_data_storage_mode_defaults_to_database" {
  command = plan

  assert {
    condition     = var.n8n_execution_data_storage_mode == "database"
    error_message = "n8n_execution_data_storage_mode should default to \"database\"."
  }
}

run "execution_data_storage_mode_accepts_s3" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
  }

  assert {
    condition     = var.n8n_execution_data_storage_mode == "s3"
    error_message = "n8n_execution_data_storage_mode should accept \"s3\"."
  }
}

run "execution_data_storage_mode_rejects_filesystem" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "filesystem"
  }

  expect_failures = [var.n8n_execution_data_storage_mode]
}

run "execution_data_storage_mode_s3_with_old_image_tag_triggers_check_warning" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
    n8n_image_tag                   = "2.26.0"
  }

  expect_failures = [check.execution_data_s3_requires_n8n_2_27]
}

run "execution_data_storage_mode_s3_with_new_image_tag_plans_cleanly" {
  command = plan

  variables {
    n8n_execution_data_storage_mode = "s3"
    n8n_image_tag                   = "2.27.4"
  }

  assert {
    condition     = var.n8n_execution_data_storage_mode == "s3"
    error_message = "execution_data_storage_mode = s3 should plan cleanly with a compatible image tag."
  }
}

# ── Floating-license shutdown default ─────────────────────────────────────────

run "license_detach_floating_on_shutdown_defaults_to_false" {
  command = plan

  assert {
    condition     = var.n8n_license_detach_floating_on_shutdown == false
    error_message = "n8n_license_detach_floating_on_shutdown should default to false to avoid multi-main shutdown/restart loops."
  }
}

run "license_detach_floating_on_shutdown_accepts_true" {
  command = plan

  variables {
    n8n_license_detach_floating_on_shutdown = true
  }

  assert {
    condition     = var.n8n_license_detach_floating_on_shutdown == true
    error_message = "n8n_license_detach_floating_on_shutdown should accept true for single-main deployments that want n8n's upstream behavior."
  }
}

# ── n8n_extra_env reserved-name expansion ─────────────────────────────────────
# Regression guards: every env var this section adds must be rejected by the
# escape hatch, keeping local.n8n_managed_env_names in sync.

run "extra_env_rejects_custom_extensions_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_CUSTOM_EXTENSIONS", value = "/opt/evil" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_license_detach_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_execution_data_storage_mode_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_EXECUTION_DATA_STORAGE_MODE", value = "s3" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_node_extra_ca_certs_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "NODE_EXTRA_CA_CERTS", value = "/tmp/unmanaged-ca.crt" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_community_packages_registry_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_COMMUNITY_PACKAGES_REGISTRY", value = "https://evil.example.com/npm" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_unverified_packages_enabled_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_UNVERIFIED_PACKAGES_ENABLED", value = "true" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_compression_max_decompressed_size_bytes_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES", value = "1" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_compression_max_zip_entries_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES", value = "1" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

# ── Canonical URL reserved names (section 19) ──────────────────────────

run "extra_env_rejects_webhook_url_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "WEBHOOK_URL", value = "https://evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_n8n_webhook_url_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_WEBHOOK_URL", value = "https://evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}

run "extra_env_rejects_editor_base_url_name" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "N8N_EDITOR_BASE_URL", value = "https://evil.example.com" },
    ]
  }

  expect_failures = [var.n8n_extra_env]
}
