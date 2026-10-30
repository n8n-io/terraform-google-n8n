# Plan-time tests for google_partner_attribution_label (goog-partner-solution,
# Google Cloud partner consumption tracking). The URN below is a made-up
# fixture, not n8n's real Marketplace consumption tracking label.
#
# helm_release.values is unknown at plan time under the mock provider (see
# AGENTS.md, "Known mock provider limitations"), so the podLabels value is
# asserted on local.n8n_pod_labels_values, which n8n.tf merges into the chart
# values verbatim; tests/scripts/check-n8n-chart.sh covers the chart side.
# Neither protects the merge itself in helm_release.n8n: verify that with a
# real `terraform plan` from an example root (podLabels in the Helm values). The
# PD CSI StorageClass parameter is a child-module resource, asserted here
# through the modules/controllers output and in modules/controllers/tests.

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

run "partner_label_off_by_default" {
  command = plan

  assert {
    condition     = length(local.google_partner_attribution_labels) == 0
    error_message = "No partner label may be derived while google_partner_attribution_label is empty"
  }

  assert {
    condition     = !contains(keys(google_container_cluster.n8n[0].resource_labels), "goog-partner-solution")
    error_message = "The cluster must not carry goog-partner-solution by default"
  }

  assert {
    condition     = length(google_container_node_pool.n8n[0].node_config[0].resource_labels) == 0
    error_message = "Node VMs must get no resource_labels by default, so node_config is unchanged for existing deployments"
  }

  assert {
    condition     = length(keys(local.n8n_pod_labels_values)) == 0
    error_message = "No podLabels may be passed to the chart by default"
  }

  assert {
    condition     = !contains(keys(module.controllers.pd_balanced_storage_class_parameters), "labels")
    error_message = "The pd-balanced StorageClass must get no PD CSI labels parameter by default"
  }
}

run "partner_label_reaches_labeled_resources_nodes_and_exporter" {
  command = plan

  variables {
    google_partner_attribution_label = "isol_plb32_0123456789abcdef"
    redis_exporter_enabled           = true
    common_labels = {
      team                    = "platform"
      "goog-partner-solution" = "caller_value"
    }
  }

  assert {
    condition     = google_container_cluster.n8n[0].resource_labels["goog-partner-solution"] == "isol_plb32_0123456789abcdef"
    error_message = "The partner label must be on the cluster, and must win over a colliding common_labels key"
  }

  assert {
    condition     = google_container_cluster.n8n[0].resource_labels["team"] == "platform"
    error_message = "common_labels must still be merged alongside the partner label"
  }

  assert {
    condition     = try(google_sql_database_instance.n8n[0].settings[0].user_labels["goog-partner-solution"], null) == "isol_plb32_0123456789abcdef"
    error_message = "The partner label must reach Cloud SQL user_labels through local.gcp_labels"
  }

  assert {
    condition     = try(google_storage_bucket.n8n[0].labels["goog-partner-solution"], null) == "isol_plb32_0123456789abcdef"
    error_message = "The partner label must reach the GCS bucket through local.gcp_labels"
  }

  assert {
    condition     = google_container_node_pool.n8n[0].node_config[0].resource_labels["goog-partner-solution"] == "isol_plb32_0123456789abcdef"
    error_message = "The partner label must be a GCE resource label on the node VMs"
  }

  assert {
    condition     = length(google_container_node_pool.n8n[0].node_config[0].resource_labels) == 1
    error_message = "Only the partner label, not all of gcp_labels, belongs in node_config.resource_labels"
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].template[0].metadata[0].labels["goog-partner-solution"] == "isol_plb32_0123456789abcdef"
    error_message = "The Redis exporter pod template must carry the partner label"
  }

  assert {
    condition     = local.n8n_pod_labels_values.podLabels["goog-partner-solution"] == "isol_plb32_0123456789abcdef" && length(keys(local.n8n_pod_labels_values.podLabels)) == 1
    error_message = "The chart's podLabels must carry only the partner label"
  }

  assert {
    condition     = module.controllers.pd_balanced_storage_class_parameters["labels"] == "goog-partner-solution=isol_plb32_0123456789abcdef"
    error_message = "The root module must pass the partner label to the pd-balanced StorageClass as a PD CSI disk label"
  }

  assert {
    condition     = kubernetes_deployment_v1.redis_exporter[0].spec[0].selector[0].match_labels["app"] == "redis-exporter"
    error_message = "The partner label must not change the exporter's selector"
  }
}

run "partner_label_rejects_invalid_value" {
  command = plan

  variables {
    google_partner_attribution_label = "ISOL:Upper"
  }

  expect_failures = [var.google_partner_attribution_label]
}

run "partner_label_rejects_overlong_value" {
  command = plan

  variables {
    google_partner_attribution_label = "a123456789012345678901234567890123456789012345678901234567890123"
  }

  expect_failures = [var.google_partner_attribution_label]
}

run "partner_label_rejects_non_alphanumeric_boundaries" {
  command = plan

  variables {
    google_partner_attribution_label = "-partner"
  }

  expect_failures = [var.google_partner_attribution_label]
}

run "partner_label_reaches_global_addresses" {
  command = plan

  variables {
    google_partner_attribution_label = "isol_plb32_0123456789abcdef"
  }

  assert {
    condition     = google_compute_global_address.lb[0].labels["goog-partner-solution"] == "isol_plb32_0123456789abcdef"
    error_message = "The load balancer's static address must carry the partner label"
  }

  assert {
    condition     = google_compute_global_address.psa[0].labels["goog-partner-solution"] == "isol_plb32_0123456789abcdef"
    error_message = "The Private Service Access range must carry the partner label"
  }
}

run "partner_label_common_labels_key_ignored_when_input_empty" {
  command = plan

  variables {
    common_labels = {
      team                    = "platform"
      "goog-partner-solution" = "caller_value"
    }
  }

  assert {
    condition     = !contains(keys(local.gcp_labels), "goog-partner-solution")
    error_message = "A goog-partner-solution key in common_labels must be ignored while google_partner_attribution_label is empty"
  }

  assert {
    condition     = google_container_cluster.n8n[0].resource_labels["team"] == "platform"
    error_message = "Other common_labels keys must still be applied"
  }

  assert {
    condition     = length(keys(local.n8n_pod_labels_values)) == 0
    error_message = "A common_labels entry must not add podLabels"
  }
}
