# ── Example: Cloudflare DNS + Let's Encrypt (validated path) ────────
# Cloudflare resolves n8n_fqdn to the LB static IP (dns.tf). TLS is an
# auto-renewing Let's Encrypt cert issued by cert-manager via a Cloudflare DNS-01
# challenge into a k8s Secret; the module's gce Ingress consumes it (tls_mode =
# secret). This keeps the Cloudflare provider and the ACME/DNS-01 token out of
# the base module.

module "n8n" {
  source = "../.."

  project_id           = var.project_id
  gcp_region           = var.gcp_region
  friendly_name_prefix = var.friendly_name_prefix
  n8n_fqdn             = var.n8n_fqdn

  n8n_license_key = var.n8n_license_key
  gcs_location    = var.gcs_location

  # Set true only if your creds have org-policy admin (see variable docs).
  manage_sa_key_org_policy = var.manage_sa_key_org_policy

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  gke_deletion_protection      = var.gke_deletion_protection
  postgres_deletion_protection = var.postgres_deletion_protection
  gcs_force_destroy            = var.gcs_force_destroy

  # DNS is managed here in Cloudflare (dns.tf), not by the module.
  cloud_dns_zone_name = ""

  # cert-manager writes the cert into this Secret; the Ingress consumes it.
  tls_mode        = "secret"
  tls_secret_name = "n8n-tls"
}
