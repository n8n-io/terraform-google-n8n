# Plan-time test proving the direct-use composition and its n8n-after-KEDA
# dependency ordering, without contacting Google Cloud.

mock_provider "google" {}
mock_provider "kubernetes" {}
mock_provider "helm" {}

variables {
  project_id       = "test-project"
  gcp_region       = "us-east4"
  gke_cluster_name = "existing-cluster"
  n8n_fqdn         = "n8n.test.example.com"
}

run "direct_use_installs_keda_and_storage_class" {
  command = plan

  assert {
    condition     = module.controllers.keda_installed == true
    error_message = "KEDA must be installed by the controllers submodule"
  }

  assert {
    condition     = module.controllers.pd_balanced_storage_class_name == "n8n-pd-balanced"
    error_message = "The pd-balanced StorageClass must be created by the controllers submodule"
  }

  assert {
    condition     = helm_release.n8n.namespace == "n8n"
    error_message = "The caller's n8n release must exist, ordered after module.controllers"
  }
}
