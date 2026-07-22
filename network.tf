# ── VPC-native networking ─────────────────────────────────────────────────────
# Custom VPC + subnet with secondary ranges for pods/services (alias IPs), Cloud
# NAT for egress from private nodes, and a Private Services Access range that
# Cloud SQL (and optionally Memorystore) peer into for private IP connectivity.

locals {
  # GCP labels: lowercase keys/values only.
  gcp_labels = {
    managed_by = "terraform"
    app        = "n8n"
    cluster    = local.cluster_name
  }
}

resource "google_compute_network" "n8n" {
  name                    = "${local.cluster_name}-vpc"
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "n8n" {
  name                     = "${local.cluster_name}-subnet"
  project                  = var.project_id
  region                   = var.gcp_region
  network                  = google_compute_network.n8n.id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${local.cluster_name}-pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "${local.cluster_name}-services"
    ip_cidr_range = var.services_cidr
  }
}

resource "google_compute_router" "n8n" {
  name    = "${local.cluster_name}-router"
  project = var.project_id
  region  = var.gcp_region
  network = google_compute_network.n8n.id
}

resource "google_compute_router_nat" "n8n" {
  name                               = "${local.cluster_name}-nat"
  project                            = var.project_id
  router                             = google_compute_router.n8n.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── Private Services Access (prerequisite for Cloud SQL private IP) ───────────
resource "google_compute_global_address" "psa" {
  name          = "${local.cluster_name}-psa"
  project       = var.project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.psa_prefix_length
  network       = google_compute_network.n8n.id
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.n8n.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
}

# ── Destroy-time pause ────────────────────────────────────────────────────────
# GCP's backend takes longer to release Cloud SQL/Redis's use of the PSA peering
# than the delete API calls for those resources take to return. Deleting the
# peering connection immediately after Cloud SQL/Redis report "destroyed" fails
# with "Producer services ... are still using this connection" every time. This
# pause gives the backend time to catch up before Terraform deletes the peering.
#
# The lag is not fixed: it has been observed anywhere from a few minutes to well
# over an hour, and GCP exposes no signal for when the release completes, so no
# single default is guaranteed. var.psa_cleanup_destroy_duration lets operators
# raise the pause; if a teardown still stalls, the reliable unblock is the
# compute-level peering delete documented in README.md ("Teardown").
#
# Dependency chain (create order, reversed for destroy):
#   psa -> time_sleep -> cloudsql/redis
# Destroy order (reversed):
#   1. google_sql_database_instance.n8n / google_redis_instance.n8n (destroyed)
#   2. time_sleep.wait_for_psa_cleanup                               (pauses)
#   3. google_service_networking_connection.psa                     (destroyed)

resource "time_sleep" "wait_for_psa_cleanup" {
  destroy_duration = var.psa_cleanup_destroy_duration

  depends_on = [google_service_networking_connection.psa]
}
