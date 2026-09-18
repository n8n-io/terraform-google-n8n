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
#
# CKV2_GCP_18 exception: google_compute_firewall.deny_all_ingress below is
# connected to this network and satisfies the check's actual requirement (a
# non-default firewall exists); Checkov's graph connection lookup does not
# resolve a count-indexed `network = google_compute_network.n8n[0].id`
# reference (reproduced against a two-resource fixture with count = 1 during
# this change's security review, where an identical firewall/network pair
# without count passed and the count-indexed pair failed), so it reports this
# false positive whenever create_network's count expression is present at
# all, regardless of value.
resource "google_compute_network" "n8n" {
  count = var.create_network ? 1 : 0

  # checkov:skip=CKV2_GCP_18: intentional, count-indexing scanner limitation, see resource comment above.

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

  # CKV_GCP_26: VPC Flow Logs for this subnet, sampled rather than exhaustive,
  # so day-2 network debugging and the GKE cluster's own intranode visibility
  # (gke.tf's enable_intranode_visibility) both have real Cloud Logging data
  # to draw on.
  log_config {
    aggregation_interval = "INTERVAL_5_SEC"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# CKV2_GCP_18: an explicit, low-priority deny-all-ingress rule so this network
# is provably not relying on any implicit default-allow behavior. Terraform
# custom-mode VPCs (auto_create_subnetworks = false, set above) already carry
# no GCP-managed default rules, and GKE's own control-plane-to-node rules are
# created outside Terraform at a higher (numerically lower) priority, so this
# rule changes no actual traffic; it only closes the gap Checkov flags when no
# firewall resource is declared for the network at all.
resource "google_compute_firewall" "deny_all_ingress" {
  count = var.create_network ? 1 : 0

  name      = "${local.name_prefix}-deny-all-ingress"
  project   = var.project_id
  network   = google_compute_network.n8n[0].id
  direction = "INGRESS"
  priority  = 65534

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
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

# deletion_policy: by default (psa_connection_abandon_on_destroy = true) the
# module never calls the servicenetworking connections.delete API on destroy.
# That API enforces a producer-side check ("Producer services ... are still
# using this connection") that lags actual Cloud SQL/Memorystore deletion by
# anywhere from minutes to days, and GCP exposes no signal for when the release
# completes, so no fixed destroy-time pause could make it reliable
# (terraform-provider-google#16275). Abandoning drops the connection from state
# so destroy proceeds to the address range and, on the module-managed path, the
# network.
#
# The peering the connection created is NOT removed by abandoning it. The
# Google provider docs and GCP's VPC docs both state that a remaining peering
# blocks network deletion; a live examples/small teardown on 2026-09-17
# nevertheless observed the VPC delete succeed with only the servicenetworking
# peering left. Treat that as observed, not guaranteed: if
# google_compute_network.n8n[0] is refused on destroy, the recovery is the
# compute-level peering delete in docs/destroy-cleanup.md. On a customer-managed
# network (create_network = false) the peering stays on the caller's VPC, which
# the module does not own; docs/destroy-cleanup.md covers removal and the
# re-deploy path. Provider >= 8.1 adds deletion_policy = "REMOVE_PEERING" for
# exactly this case; adopt it when the google constraint moves past 6.x.
#
# psa_connection_abandon_on_destroy = false leaves deletion_policy unset so the
# provider attempts the API delete (may stall on the producer check).
#
# Cloud SQL / Memorystore depend on this resource directly (cloudsql.tf,
# memorystore.tf) so creation still waits for the peering to exist.
resource "google_service_networking_connection" "psa" {
  count = var.create_psa ? 1 : 0

  network                 = local.effective_network_id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa[0].name]

  deletion_policy = var.psa_connection_abandon_on_destroy ? "ABANDON" : null
}
