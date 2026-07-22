# ── Static IP, DNS, and TLS certs ─────────────────────────────────────────────
# The native gce Ingress (n8n.tf) attaches to a reserved global static IP; the
# LB terminates TLS. This file owns: the static IP, the optional Google Cloud
# DNS A-record (base/default path; examples/cloudflare manages its own record),
# and the pre-shared SSL certificate for tls_mode custom / self_signed.
#
# tls_mode wiring:
#   google_managed -> ManagedCertificate CR (crds.tf), referenced by annotation
#   custom         -> google_compute_ssl_certificate from caller PEM (here)
#   self_signed    -> google_compute_ssl_certificate from a generated cert (here)
#   secret         -> Ingress spec.tls consumes an external k8s Secret (n8n.tf)

locals {
  tls_preshared = contains(["custom", "self_signed"], var.tls_mode)
}

# ── Global static IP for the L7 load balancer ─────────────────────────────────
resource "google_compute_global_address" "lb" {
  name    = "${local.cluster_name}-lb-ip"
  project = var.project_id
}

# ── Google Cloud DNS A-record (base/default path) ─────────────────────────────
# Only when dns_managed_zone is set. Alternative DNS providers (Cloudflare,
# GoDaddy) manage their own record against google_compute_global_address.lb in
# the respective examples.
resource "google_dns_record_set" "n8n" {
  count = var.dns_managed_zone != "" ? 1 : 0

  project      = var.project_id
  managed_zone = var.dns_managed_zone
  name         = "${var.n8n_domain}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb.address]
}

# ── Self-signed cert material (tls_mode = self_signed) ────────────────────────
resource "tls_private_key" "self_signed" {
  count     = var.tls_mode == "self_signed" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  count           = var.tls_mode == "self_signed" ? 1 : 0
  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name = var.n8n_domain
  }

  dns_names             = [var.n8n_domain]
  validity_period_hours = 8760
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
}

# ── Pre-shared SSL certificate (custom or self_signed) ────────────────────────
resource "google_compute_ssl_certificate" "n8n" {
  count   = local.tls_preshared ? 1 : 0
  project = var.project_id

  name_prefix = "${local.cluster_name}-cert-"
  certificate = var.tls_mode == "custom" ? var.tls_cert_pem : tls_self_signed_cert.self_signed[0].cert_pem
  private_key = var.tls_mode == "custom" ? var.tls_key_pem : tls_private_key.self_signed[0].private_key_pem

  lifecycle {
    create_before_destroy = true
  }
}
