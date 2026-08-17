# ── VPC-native networking ─────────────────────────────────────────────────────
# Custom VPC + subnet with secondary ranges for pods/services (alias IPs), Cloud
# NAT for egress from private nodes, and a Private Services Access range that
# Cloud SQL (and optionally Memorystore) peer into for private IP connectivity.

locals {
  # GCP labels: lowercase keys/values only. common_labels is merged in first so
  # the module's own built-in labels win on key collision.
  gcp_labels = merge(var.common_labels, {
    managed_by = "terraform"
    app        = "n8n"
    cluster    = local.name_prefix
  })
}

# create_network gates the VPC, subnetwork, secondary ranges, router, and NAT
# as a single unit (D2): with create_network = false the caller supplies an
# existing network, subnetwork, and secondary range names instead (see
# variables_gcp.tf and locals.tf's effective_* network locals).
resource "google_compute_network" "n8n" {
  count = var.create_network ? 1 : 0

  name                    = "${local.name_prefix}-vpc"
  auto_create_subnetworks = false
  project                 = var.project_id
}

resource "google_compute_subnetwork" "n8n" {
  count = var.create_network ? 1 : 0

  name                     = "${local.name_prefix}-subnet"
  project                  = var.project_id
  region                   = var.gcp_region
  network                  = google_compute_network.n8n[0].id
  ip_cidr_range            = var.subnet_cidr
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "${local.name_prefix}-pods"
    ip_cidr_range = var.pods_cidr
  }
  secondary_ip_range {
    range_name    = "${local.name_prefix}-services"
    ip_cidr_range = var.services_cidr
  }
}

resource "google_compute_router" "n8n" {
  count = var.create_network ? 1 : 0

  name    = "${local.name_prefix}-router"
  project = var.project_id
  region  = var.gcp_region
  network = google_compute_network.n8n[0].id
}

resource "google_compute_router_nat" "n8n" {
  count = var.create_network ? 1 : 0

  name                               = "${local.name_prefix}-nat"
  project                            = var.project_id
  router                             = google_compute_router.n8n[0].name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ── Private Services Access (prerequisite for Cloud SQL private IP) ───────────
# create_psa is independent of create_network (D2): the module can manage the
# PSA allocation and connection on either a module-managed or an existing
# network, so these reference local.effective_network_id rather than the
# google_compute_network resource directly.
resource "google_compute_global_address" "psa" {
  count = var.create_psa ? 1 : 0

  name          = "${local.name_prefix}-psa"
  project       = local.effective_network_project_id
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.psa_prefix_length
  network       = local.effective_network_id
}

resource "google_service_networking_connection" "psa" {
  count = var.create_psa ? 1 : 0

  network                 = local.effective_network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa[0].name]
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
  count = var.create_psa ? 1 : 0

  destroy_duration = var.psa_cleanup_destroy_duration

  depends_on = [google_service_networking_connection.psa]
}
