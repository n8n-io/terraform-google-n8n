# ── Split-ingress networking prerequisites (task 21.2) ─────────────────────────
# Google's regional internal Application Load Balancer (the internal GKE
# Ingress class "gce-internal") needs a proxy-only subnet and a firewall rule
# letting its managed proxies reach the backend pods; neither is created
# automatically by the Ingress controller. The public ingress ("gce") reuses
# GKE's own automatically managed health-check firewall rule, so nothing
# extra is created for it here.
# https://docs.cloud.google.com/kubernetes-engine/docs/how-to/internal-load-balance-ingress

# Global external static IP for the public webhook-only ingress.
resource "google_compute_global_address" "public" {
  name    = "${var.friendly_name_prefix}-n8n-public"
  project = var.project_id
}

# Regional internal static IP for the private editor+webhook ingress. Must be
# in the same VPC/region as the GKE cluster; reusing the module's own node
# subnetwork (not the proxy-only subnet, which never holds forwarding-rule
# IPs).
resource "google_compute_address" "private" {
  name         = "${var.friendly_name_prefix}-n8n-private"
  project      = var.project_id
  region       = var.gcp_region
  subnetwork   = module.n8n.subnetwork_self_link
  address_type = "INTERNAL"
}

# Proxy-only subnet: dedicated address space the regional internal ALB's
# managed proxies use to connect to backends. Not a workload subnet; no
# pods/nodes/services are ever assigned addresses from this range.
resource "google_compute_subnetwork" "proxy_only" {
  name          = "${var.friendly_name_prefix}-n8n-proxy-only"
  project       = var.project_id
  region        = var.gcp_region
  network       = module.n8n.network_id
  ip_cidr_range = var.proxy_only_subnet_cidr
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
}

# Scoped firewall rule: let the regional ALB's managed proxies (sourced from
# the proxy-only subnet above) reach n8n's Service port on cluster nodes/pods.
# This is the one firewall rule GKE's Ingress controller does NOT create for
# you (it does create the external health-check rule automatically). Scoped
# by protocol/port and by source range to the proxy-only subnet; GKE assigns
# node network tags dynamically per cluster/node-pool, so this rule is scoped
# to the module's own dedicated VPC (network.tf's create_network default)
# rather than to a target tag that cannot be known before apply.
resource "google_compute_firewall" "allow_proxy_connection" {
  name    = "${var.friendly_name_prefix}-n8n-allow-proxy-connection"
  project = var.project_id
  network = module.n8n.network_id

  direction     = "INGRESS"
  source_ranges = [var.proxy_only_subnet_cidr]

  allow {
    protocol = "tcp"
    ports    = [tostring(module.n8n.n8n_service_port)]
  }
}
