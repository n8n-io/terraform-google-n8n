# Plan-time tests for section 11: credential-overwrite Secret reference
# (n8n_credentials_overwrite_secret_ref).
#
# helm_release.n8n.values is a JSON-encoded string, unknown at plan time under
# the mock provider (see AGENTS.md's known mock-provider limitations), so the
# rendered extraVolumes/extraVolumeMounts/extraEnv shape is asserted against
# local.n8n_credentials_overwrite_volume/n8n_credentials_overwrite_mount
# directly (permitted per AGENTS.md: "A terraform test assert condition can
# reference module local.* values directly"), and everything else is
# asserted at the variable-contract layer.

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

run "credentials_overwrite_defaults_to_disabled" {
  command = plan

  assert {
    condition     = var.n8n_credentials_overwrite_secret_ref == null
    error_message = "n8n_credentials_overwrite_secret_ref should default to null."
  }

  assert {
    condition     = local.n8n_credentials_overwrite_enabled == false
    error_message = "Credential overwrites should be disabled by default."
  }

  assert {
    condition     = local.n8n_credentials_overwrite_volume == null && local.n8n_credentials_overwrite_mount == null
    error_message = "No volume/mount fragment should be built while disabled."
  }
}

# ── Enabled: all three roles get the same file path ────────────────────────

run "credentials_overwrite_wires_selected_key_and_path" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "my-credential-overwrites"
      key  = "overwrites.json"
    }
  }

  assert {
    condition     = local.n8n_credentials_overwrite_enabled == true
    error_message = "Credential overwrites should be enabled once the reference is set."
  }

  assert {
    condition     = local.n8n_credentials_overwrite_volume.secret.secretName == "my-credential-overwrites"
    error_message = "The volume should reference the caller-supplied Secret name."
  }

  assert {
    condition     = local.n8n_credentials_overwrite_volume.secret.items[0].key == "overwrites.json"
    error_message = "The volume should mount only the caller-selected key."
  }

  assert {
    condition     = local.n8n_credentials_overwrite_mount.mountPath == "/etc/n8n/credentials-overwrite/overwrites.json"
    error_message = "All three n8n roles should mount the file at the documented path (config.extraVolumeMounts applies to main, worker, and webhook-processor containers alike)."
  }

  assert {
    condition     = local.n8n_credentials_overwrite_mount.readOnly == true
    error_message = "The mount should be read-only."
  }
}

run "credentials_overwrite_rejects_blank_name_or_key" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = " "
      key  = "overwrites.json"
    }
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

# ── Collision guards, enabled ───────────────────────────────────────────────

run "credentials_overwrite_rejects_volume_name_collision" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "my-credential-overwrites"
      key  = "overwrites.json"
    }
    n8n_extra_volumes = [{
      name       = "credentials-overwrite"
      config_map = { name = "some-configmap" }
    }]
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

run "credentials_overwrite_rejects_mount_path_collision" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "my-credential-overwrites"
      key  = "overwrites.json"
    }
    n8n_extra_volumes = [{
      name       = "other-vol"
      config_map = { name = "some-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "other-vol"
      mount_path = "/etc/n8n/credentials-overwrite/overwrites.json"
    }]
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

run "credentials_overwrite_rejects_parent_directory_mount_overlap" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "my-credential-overwrites"
      key  = "overwrites.json"
    }
    n8n_extra_volumes = [{
      name       = "other-vol"
      config_map = { name = "some-configmap" }
    }]
    n8n_extra_volume_mounts = [{
      name       = "other-vol"
      mount_path = "/etc/n8n/credentials-overwrite"
    }]
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

run "credentials_overwrite_rejects_reserved_env_name_collision" {
  command = plan

  variables {
    n8n_credentials_overwrite_secret_ref = {
      name = "my-credential-overwrites"
      key  = "overwrites.json"
    }
    n8n_extra_env = [
      { name = "CREDENTIALS_OVERWRITE_DATA_FILE", value = "/some/other/path.json" },
    ]
  }

  expect_failures = [var.n8n_credentials_overwrite_secret_ref]
}

# ── Disabled escape hatch remains accepted ─────────────────────────────────

run "credentials_overwrite_disabled_leaves_extra_env_escape_hatch_usable" {
  command = plan

  variables {
    n8n_extra_env = [
      { name = "CREDENTIALS_OVERWRITE_DATA_FILE", value = "/some/other/path.json" },
    ]
  }

  assert {
    condition     = length(var.n8n_extra_env) == 1
    error_message = "CREDENTIALS_OVERWRITE_DATA_FILE should remain usable through n8n_extra_env while the dedicated input is disabled."
  }
}

run "credentials_overwrite_disabled_leaves_reserved_volume_name_usable" {
  command = plan

  variables {
    n8n_extra_volumes = [{
      name       = "credentials-overwrite"
      config_map = { name = "some-configmap" }
    }]
  }

  assert {
    condition     = length(var.n8n_extra_volumes) == 1
    error_message = "The \"credentials-overwrite\" volume name should remain usable while the dedicated input is disabled."
  }
}
