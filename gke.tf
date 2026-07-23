# ── GKE cluster + node pool ───────────────────────────────────────────────────
# Regional, VPC-native cluster with Workload Identity enabled. Node-pool
# autoscaling is native to GKE. The default node pool is removed and a managed
# pool is attached so its shape is fully declared here.

resource "google_container_cluster" "n8n" {
  name     = local.name_prefix
  project  = var.project_id
  location = var.gcp_region

  network    = google_compute_network.n8n.id
  subnetwork = google_compute_subnetwork.n8n.id

  # Manage the node pool as a separate resource.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = var.gke_deletion_protection

  release_channel {
    channel = var.gke_release_channel
  }
  min_master_version = var.gke_min_master_version != "" ? var.gke_min_master_version : null

  # VPC-native (alias IPs) using the subnet's secondary ranges.
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "${local.name_prefix}-pods"
    services_secondary_range_name = "${local.name_prefix}-services"
  }

  # Workload Identity: bind KSAs to Google service accounts.
  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  private_cluster_config {
    enable_private_nodes    = var.gke_enable_private_nodes
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.gke_enable_private_nodes ? var.gke_control_plane_cidr : null
  }

  dynamic "master_authorized_networks_config" {
    for_each = length(var.gke_control_plane_authorized_networks) > 0 ? [1] : []
    content {
      dynamic "cidr_blocks" {
        for_each = var.gke_control_plane_authorized_networks
        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  resource_labels = local.gcp_labels

  # PSA peering must exist before the cluster if Cloud SQL/Memorystore are used.
  depends_on = [google_service_networking_connection.psa]
}

# ── Node service account (least privilege) ────────────────────────────────────
# Without an explicit service_account, GKE nodes run as the project's default
# Compute Engine SA, which often carries broad roles (Editor). Nodes keep the
# cloud-platform OAuth scope (Google's current guidance); the IAM roles on this
# dedicated SA are what actually bound node-level access. Pod-level access to
# Google APIs goes through Workload Identity (workload_identity.tf), not this SA.

locals {
  # Minimal role set Google recommends for GKE node service accounts:
  # logging/monitoring pipelines plus image pulls from Artifact Registry.
  node_sa_roles = [
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ]
}

resource "google_service_account" "nodes" {
  account_id   = substr("${local.name_prefix}-nodes", 0, 30)
  project      = var.project_id
  display_name = "GKE node pool (${local.name_prefix})"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset(local.node_sa_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_node_pool" "n8n" {
  name     = "${local.name_prefix}-pool"
  project  = var.project_id
  location = var.gcp_region
  cluster  = google_container_cluster.n8n.name

  autoscaling {
    min_node_count = var.gke_node_min_per_zone
    max_node_count = var.gke_node_max_per_zone
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.gke_node_type
    disk_size_gb = var.gke_node_disk_size_gb
    disk_type    = var.gke_node_disk_type

    # Dedicated least-privilege SA; see the node service account section above.
    service_account = google_service_account.nodes.email

    # Cloud API access; fine-grained authz is via Workload Identity per pod.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # Required so pods can use Workload Identity.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = local.gcp_labels
  }

  # Nodes must come up with their logging/monitoring roles already granted, or
  # early node logs are dropped; node_config.service_account only implies a
  # dependency on the SA itself, not on the role bindings.
  depends_on = [google_project_iam_member.nodes]
}
