# ── Example: GoDaddy DNS + Google-managed TLS ─────────────────────────────────
# GoDaddy resolves n8n_fqdn to the LB static IP (dns.tf). TLS is a
# Google-managed certificate: once the A-record resolves to the load balancer,
# the ManagedCertificate provisions automatically (takes a few minutes). DNS is
# managed here via the GoDaddy provider, not by the module, so cloud_dns_zone_name
# is left empty.

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

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  gke_deletion_protection      = var.gke_deletion_protection
  postgres_deletion_protection = var.postgres_deletion_protection
  gcs_force_destroy            = var.gcs_force_destroy

  # DNS is managed here in GoDaddy (dns.tf), not by the module.
  cloud_dns_zone_name = ""

  # Google-managed cert; provisions once the GoDaddy A-record resolves.
  tls_mode = "google_managed"
}
