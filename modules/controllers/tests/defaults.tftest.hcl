# Plan-time tests for the modules/controllers submodule using mocked
# providers. Exercises KEDA and the pd-balanced StorageClass directly (without
# the root module) so this submodule's public contract is proven independent
# of the root wrapper. All providers are mocked, so no credentials or network
# access are required and the suite runs offline.
#
# Run: terraform test (from modules/controllers - requires terraform >= 1.11)

mock_provider "kubernetes" {}
mock_provider "helm" {}

run "defaults_install_both_components" {
  command = plan

  assert {
    condition     = helm_release.keda[0].chart == "keda"
    error_message = "KEDA helm release must be created by default"
  }

  assert {
    condition     = helm_release.keda[0].repository == "https://kedacore.github.io/charts"
    error_message = "keda_chart_repository must default to the public kedacore charts repository"
  }

  assert {
    condition     = helm_release.keda[0].namespace == "keda"
    error_message = "KEDA must install into its own 'keda' namespace by default"
  }

  assert {
    condition     = helm_release.keda[0].version == "2.20.1"
    error_message = "KEDA chart version must default to 2.20.1"
  }

  assert {
    condition     = kubernetes_storage_class_v1.pd_balanced[0].metadata[0].name == "n8n-pd-balanced"
    error_message = "pd-balanced StorageClass must be created by default"
  }

  assert {
    condition     = kubernetes_storage_class_v1.pd_balanced[0].storage_provisioner == "pd.csi.storage.gke.io"
    error_message = "StorageClass must use the GCE PD CSI provisioner"
  }

  assert {
    condition     = kubernetes_storage_class_v1.pd_balanced[0].volume_binding_mode == "WaitForFirstConsumer"
    error_message = "StorageClass must use WaitForFirstConsumer so volumes land in the consumer pod's zone"
  }

  assert {
    condition     = kubernetes_storage_class_v1.pd_balanced[0].reclaim_policy == "Delete"
    error_message = "StorageClass must use the Delete reclaim policy to limit orphaned disks"
  }

  assert {
    condition     = kubernetes_storage_class_v1.pd_balanced[0].allow_volume_expansion == true
    error_message = "StorageClass must allow volume expansion"
  }

  assert {
    condition     = kubernetes_storage_class_v1.pd_balanced[0].parameters["type"] == "pd-balanced"
    error_message = "StorageClass must provision pd-balanced disks"
  }

  assert {
    condition     = output.keda_installed == true
    error_message = "keda_installed output must be true by default"
  }

  assert {
    condition     = output.pd_balanced_storage_class_name == "n8n-pd-balanced"
    error_message = "pd_balanced_storage_class_name output must reflect the created StorageClass"
  }
}

run "keda_can_be_opted_out_independently" {
  command = plan

  variables {
    install_keda = false
  }

  assert {
    condition     = length(helm_release.keda) == 0
    error_message = "No KEDA helm release should exist when install_keda = false"
  }

  assert {
    condition     = length(kubernetes_storage_class_v1.pd_balanced) == 1
    error_message = "Disabling KEDA must not disable the StorageClass"
  }

  assert {
    condition     = output.keda_installed == false
    error_message = "keda_installed output must be false when install_keda = false"
  }

  assert {
    condition     = output.keda_namespace == null
    error_message = "keda_namespace output must be null when install_keda = false"
  }

  assert {
    condition     = output.keda_release_name == null
    error_message = "keda_release_name output must be null when install_keda = false"
  }

  assert {
    condition     = output.keda_chart_version == null
    error_message = "keda_chart_version output must be null when install_keda = false"
  }
}

run "storage_class_can_be_opted_out_independently" {
  command = plan

  variables {
    create_pd_balanced_storage_class = false
  }

  assert {
    condition     = length(kubernetes_storage_class_v1.pd_balanced) == 0
    error_message = "No StorageClass should exist when create_pd_balanced_storage_class = false"
  }

  assert {
    condition     = length(helm_release.keda) == 1
    error_message = "Disabling the StorageClass must not disable KEDA"
  }

  assert {
    condition     = output.pd_balanced_storage_class_name == null
    error_message = "pd_balanced_storage_class_name output must be null when create_pd_balanced_storage_class = false"
  }
}

run "private_repository_is_honored" {
  command = plan

  variables {
    keda_chart_repository = "oci://registry.example.com/charts"
  }

  assert {
    condition     = helm_release.keda[0].repository == "oci://registry.example.com/charts"
    error_message = "A private OCI chart repository must be used when supplied"
  }
}

run "chart_repository_rejects_unsupported_scheme" {
  command = plan

  variables {
    keda_chart_repository = "ftp://example.com/charts"
  }

  expect_failures = [var.keda_chart_repository]
}

run "chart_version_rejects_floating_tag" {
  command = plan

  variables {
    keda_chart_version = "latest"
  }

  expect_failures = [var.keda_chart_version]
}

run "chart_version_rejects_version_range" {
  command = plan

  variables {
    keda_chart_version = "~> 2.20"
  }

  expect_failures = [var.keda_chart_version]
}

run "chart_version_accepts_exact_semver" {
  command = plan

  variables {
    keda_chart_version = "2.21.0"
  }

  assert {
    condition     = helm_release.keda[0].version == "2.21.0"
    error_message = "An exact semantic version must be accepted and applied"
  }
}

run "custom_storage_class_name_and_labels" {
  command = plan

  variables {
    pd_balanced_storage_class_name = "custom-pd-balanced"
    common_labels                  = { team = "platform" }
  }

  assert {
    condition     = kubernetes_storage_class_v1.pd_balanced[0].metadata[0].name == "custom-pd-balanced"
    error_message = "A custom StorageClass name must be honored"
  }

  assert {
    condition     = kubernetes_storage_class_v1.pd_balanced[0].metadata[0].labels["team"] == "platform"
    error_message = "common_labels must be applied to the StorageClass"
  }
}
