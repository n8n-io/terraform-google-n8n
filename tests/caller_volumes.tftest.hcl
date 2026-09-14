# Plan-time tests for section 10: caller-managed volumes
# (n8n_extra_volumes / n8n_extra_volume_mounts).
#
# helm_release.n8n.values is a JSON-encoded string, unknown at plan time under
# the mock provider (see AGENTS.md's known mock-provider limitations), so the
# rendered extraVolumes/extraVolumeMounts shape is asserted against
# local.n8n_caller_extra_volumes/n8n_caller_extra_volume_mounts directly
# (permitted per AGENTS.md: "A terraform test assert condition can reference
# module local.* values directly"), and everything else is asserted at the
# variable-contract layer. The chart's actual rendering of a combined
# Redis-CA-plus-caller-volumes fixture is covered by
# tests/scripts/check-n8n-chart.sh, not here.

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

# ── Defaults ───────────────────────────────────────────────────────────────

run "extra_volumes_default_to_empty" {
  command = plan

  assert {
    condition     = length(var.n8n_extra_volumes) == 0 && length(var.n8n_extra_volume_mounts) == 0
    error_message = "n8n_extra_volumes and n8n_extra_volume_mounts should default to empty lists."
  }

  assert {
    condition     = length(local.n8n_caller_extra_volumes) == 0 && length(local.n8n_caller_extra_volume_mounts) == 0
    error_message = "The caller-derived chart fragments should be empty when no volumes are declared."
  }
}

# ── Single-source validation ───────────────────────────────────────────────

run "extra_volumes_rejects_multiple_sources" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "bad-volume"
      config_map = { name = "some-configmap" }
      secret     = { name = "some-secret" }
    }]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_rejects_no_source" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name = "bad-volume"
    }]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_accepts_config_map_source" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
  }

  assert {
    condition     = length(var.n8n_extra_volumes) == 1
    error_message = "A single-source config_map volume should be accepted."
  }
}

run "extra_volumes_accepts_secret_source" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name   = "custom-secret-vol"
      secret = { name = "custom-secret" }
    }]
  }

  assert {
    condition     = length(var.n8n_extra_volumes) == 1
    error_message = "A single-source secret volume should be accepted."
  }
}

run "extra_volumes_accepts_pvc_source" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name                    = "shared-data"
      persistent_volume_claim = { claim_name = "shared-data-pvc" }
    }]
  }

  assert {
    condition     = length(var.n8n_extra_volumes) == 1
    error_message = "A single-source persistent_volume_claim volume should be accepted."
  }
}

# ── Name validation and uniqueness ────────────────────────────────────────

run "extra_volumes_rejects_invalid_name" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "Invalid_Name"
      config_map = { name = "some-configmap" }
    }]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_rejects_duplicate_names" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "dup", config_map = { name = "cm-a" } },
      { name = "dup", config_map = { name = "cm-b" } },
    ]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_rejects_reserved_name" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "redis-ca"
      config_map = { name = "some-configmap" }
    }]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_rejects_reserved_data_name" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "data"
      config_map = { name = "some-configmap" }
    }]
  }

  expect_failures = [var.n8n_extra_volumes]
}

# ── Item path validation ──────────────────────────────────────────────────

run "extra_volumes_rejects_absolute_item_path" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name = "custom-nodes"
      config_map = {
        name  = "custom-nodes-configmap"
        items = [{ key = "node.js", path = "/etc/passwd" }]
      }
    }]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_rejects_traversal_item_path" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name = "custom-nodes"
      config_map = {
        name  = "custom-nodes-configmap"
        items = [{ key = "node.js", path = "../escape" }]
      }
    }]
  }

  expect_failures = [var.n8n_extra_volumes]
}

# ── Permission mode conversion (0440 -> 288) ──────────────────────────────

run "extra_volumes_rejects_invalid_default_mode" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name = "custom-secret-vol"
      secret = {
        name         = "custom-secret"
        default_mode = "0999"
      }
    }]
  }

  expect_failures = [var.n8n_extra_volumes]
}

run "extra_volumes_converts_octal_default_mode_to_decimal" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name = "custom-secret-vol"
      secret = {
        name         = "custom-secret"
        default_mode = "0440"
      }
    }]
  }

  assert {
    condition     = local.n8n_caller_extra_volumes[0].secret.defaultMode == 288
    error_message = "Octal default_mode \"0440\" should convert to decimal 288, not 440."
  }
}

# ── Mounts: reference, uniqueness, canonical path, protected overlap ──────

run "extra_volume_mounts_rejects_undeclared_volume_reference" {
  command = plan

  variables {
    n8n_extra_volume_mounts = [{
      name       = "not-declared"
      mount_path = "/opt/n8n-nodes"
    }]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "extra_volume_mounts_accepts_declared_volume" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "custom-nodes"
      mount_path = "/opt/n8n-nodes"
    }]
  }

  assert {
    condition     = local.n8n_caller_extra_volume_mounts[0].mountPath == "/opt/n8n-nodes"
    error_message = "A valid mount referencing a declared volume should be accepted and wired into the chart fragment."
  }

  assert {
    condition     = local.n8n_caller_extra_volume_mounts[0].readOnly == true
    error_message = "read_only should default to true."
  }
}

run "extra_volume_mounts_rejects_duplicate_names" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [
      { name = "custom-nodes", mount_path = "/opt/n8n-nodes" },
      { name = "custom-nodes", mount_path = "/opt/n8n-nodes-2" },
    ]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "extra_volume_mounts_rejects_duplicate_paths" {
  command = plan

  variables {
    n8n_extra_volumes = [
      { name = "cm-a", config_map = { name = "cm-a-configmap" } },
      { name = "cm-b", config_map = { name = "cm-b-configmap" } },
    ]
    n8n_extra_volume_mounts = [
      { name = "cm-a", mount_path = "/opt/n8n-nodes" },
      { name = "cm-b", mount_path = "/opt/n8n-nodes" },
    ]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "extra_volume_mounts_rejects_relative_path" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "custom-nodes"
      mount_path = "opt/n8n-nodes"
    }]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "extra_volume_mounts_rejects_trailing_slash" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "custom-nodes"
      mount_path = "/opt/n8n-nodes/"
    }]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "extra_volume_mounts_rejects_double_slash" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "custom-nodes"
      mount_path = "/opt//n8n-nodes"
    }]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "extra_volume_mounts_rejects_home_node_n8n_overlap" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "custom-nodes"
      mount_path = "/home/node/.n8n/extra"
    }]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

run "extra_volume_mounts_rejects_redis_ca_mount_overlap" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "custom-nodes"
      mount_path = "/etc/n8n-certs/other.crt"
    }]
  }

  expect_failures = [var.n8n_extra_volume_mounts]
}

# ── Coexistence with the managed Redis CA mount ───────────────────────────

run "caller_mounts_coexist_with_managed_redis_tls" {
  command = plan

  variables {
    create_redis_instance            = true
    redis_transit_encryption_enabled = true
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "custom-nodes"
      mount_path = "/opt/n8n-nodes"
    }]
  }

  assert {
    condition     = local.manage_redis_tls_ca == true
    error_message = "This test setup should select the module-managed Redis TLS CA path."
  }

  assert {
    condition     = length(local.n8n_caller_extra_volumes) == 1
    error_message = "The caller-derived volume list should carry only the caller's own volume; the managed Redis CA volume is concatenated separately in n8n.tf, not merged into this local."
  }

  assert {
    condition     = local.n8n_caller_extra_volumes[0].name == "custom-nodes"
    error_message = "The caller's declared volume should be present."
  }
}

# ── Custom extensions path covered by a caller mount (task 10.3) ─────────

run "custom_extensions_path_covered_by_mount_silences_warning" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes"
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "custom-nodes"
      mount_path = "/opt/n8n-nodes"
    }]
  }

  assert {
    condition     = var.n8n_custom_extensions_path == "/opt/n8n-nodes"
    error_message = "n8n_custom_extensions_path should be accepted."
  }
}

run "custom_extensions_path_uncovered_still_warns" {
  command = plan

  variables {
    n8n_custom_extensions_path = "/opt/n8n-nodes"
    n8n_extra_volumes = [{
      name       = "custom-nodes"
      config_map = { name = "custom-nodes-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "custom-nodes"
      mount_path = "/opt/other-path"
    }]
  }

  expect_failures = [check.custom_extensions_path_requires_a_custom_image]
}
