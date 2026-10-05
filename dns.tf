# ── Static IP, DNS, TLS certs, and ingress security policies ─────────────────
# The native gce Ingress (n8n.tf) attaches to a reserved global static IP; the
# LB terminates TLS. This file owns: the static IP, the optional Google Cloud
# DNS A-record (base/default path; examples/cloudflare manages its own record),
# the pre-shared SSL certificate for tls_mode custom / self_signed, and the
# optional module-created Cloud Armor security policy. All of it is gated by
# create_ingress = false (D9): a caller who owns ingress also owns DNS, TLS,
# and any source-restriction policy out of band.
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
  count = var.create_ingress ? 1 : 0

  name    = "${local.name_prefix}-lb-ip"
  project = var.project_id
}

# ── Google Cloud DNS A-records (base/default path) ────────────────────────────
# Only when cloud_dns_zone_name is set. Alternative DNS providers (Cloudflare,
# GoDaddy) manage their own record against google_compute_global_address.lb in
# the respective examples. One record per effective ingress host (task 20.2:
# n8n_fqdn plus every n8n_additional_domains entry) in the single configured
# zone; a caller whose aliases live in a different Cloud DNS zone (or a
# different provider) manages those records themselves, the same way
# examples/cloudflare and examples/godaddy already manage the canonical
# record out of band.
#
# Keyed by hostname (for_each), not index, so the canonical record's resource
# instance key stays local.n8n_fqdn regardless of how n8n_additional_domains
# changes afterwards. Terraform's `moved` block requires a static (literal)
# index, so it cannot express the count[0] -> for_each[n8n_fqdn] migration
# for a caller upgrading from a pre-20.2 release; that one-time transition
# needs a manual `terraform state mv 'google_dns_record_set.n8n[0]'
# 'google_dns_record_set.n8n["<n8n_fqdn value>"]'` before apply, documented
# in docs/upgrading-n8n.md's "Cloud DNS record: `count` to `for_each`" section,
# to avoid an unnecessary record delete/recreate.
resource "google_dns_record_set" "n8n" {
  for_each = var.create_ingress && var.cloud_dns_zone_name != "" ? toset(local.n8n_effective_ingress_hosts) : toset([])

  project      = var.project_id
  managed_zone = var.cloud_dns_zone_name
  name         = "${each.value}."
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.lb[0].address]
}

# ── Self-signed cert material (tls_mode = self_signed) ────────────────────────
resource "tls_private_key" "self_signed" {
  count     = var.create_ingress && var.tls_mode == "self_signed" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  count           = var.create_ingress && var.tls_mode == "self_signed" ? 1 : 0
  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name = var.n8n_fqdn
  }

  # SANs cover every effective ingress host (task 20.2), not just the
  # canonical common_name, so an alias hostname also gets a valid self-signed
  # cert instead of only satisfying browser/client SNI on n8n_fqdn.
  dns_names             = local.n8n_effective_ingress_hosts
  validity_period_hours = 8760
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]

  lifecycle {
    # RFC 5280 caps a certificate's Common Name at 64 octets, tighter than
    # the 253-octet whole-hostname limit n8n_fqdn's own validation enforces.
    # Catch it here, at plan, rather than letting the tls provider fail mid-apply.
    precondition {
      condition     = length(var.n8n_fqdn) <= 64
      error_message = "n8n_fqdn is ${length(var.n8n_fqdn)} characters, but tls_mode = self_signed writes it into the certificate's Common Name, which RFC 5280 caps at 64 characters. Shorten n8n_fqdn, or switch tls_mode to google_managed/custom/secret, where the hostname is carried as a Subject Alternative Name instead (253-character limit)."
    }
  }
}

# ── Pre-shared SSL certificate (custom or self_signed) ────────────────────────
resource "google_compute_ssl_certificate" "n8n" {
  count   = var.create_ingress && local.tls_preshared ? 1 : 0
  project = var.project_id

  name_prefix = "${local.name_prefix}-cert-"
  certificate = var.tls_mode == "custom" ? var.tls_cert_pem : tls_self_signed_cert.self_signed[0].cert_pem
  private_key = var.tls_mode == "custom" ? var.tls_key_pem : tls_private_key.self_signed[0].private_key_pem

  lifecycle {
    create_before_destroy = true
  }
}

# ── Cloud Armor security policy (managed-ingress source restriction) ─────────
# ingress_source_cidrs and existing_cloud_armor_policy_name are mutually
# exclusive (validated on the variable itself); the effective policy name
# below resolves to whichever one is set, or null for no source restriction.
# Attached to the ingress via BackendConfig.spec.securityPolicy (crds.tf).
resource "google_compute_security_policy" "n8n" {
  count = var.create_ingress && length(var.ingress_source_cidrs) > 0 ? 1 : 0

  name    = "${local.name_prefix}-armor"
  project = var.project_id

  rule {
    action      = "deny(403)"
    priority    = 900
    description = "Block the log4j2 JNDI message-lookup pattern (CVE-2021-44228, log4jshell)"

    match {
      expr {
        expression = "evaluatePreconfiguredExpr('cve-canary')"
      }
    }
  }

  rule {
    action      = "allow"
    priority    = 1000
    description = "Allow listed source CIDRs (ingress_source_cidrs)"

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = var.ingress_source_cidrs
      }
    }
  }

  rule {
    action      = "deny(403)"
    priority    = 2147483647
    description = "Default deny for sources not in ingress_source_cidrs"

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

locals {
  effective_cloud_armor_policy_name = var.create_ingress ? (
    length(var.ingress_source_cidrs) > 0 ? google_compute_security_policy.n8n[0].name : var.existing_cloud_armor_policy_name
  ) : null
}
