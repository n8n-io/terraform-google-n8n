# ── Example: small / default (Google Cloud DNS + Google-managed TLS) ──────────
# The base-module default path: the module creates the VPC, GKE
# cluster, Cloud SQL, Memorystore, GCS, and manages the DNS A-record in Google
# Cloud DNS. TLS is a Google-managed certificate.
#
# NOTE: google_managed TLS is validated end to end (cert issued, HTTPS reachable).
# The DNS A-record must point at the LB static IP before the cert can provision,
# which then takes a few minutes. The examples/cloudflare path (Let's Encrypt) is
# an alternative if you manage DNS in Cloudflare.

module "n8n" {
  source = "../.."

  project_id           = var.project_id
  gcp_region           = var.gcp_region
  friendly_name_prefix = var.friendly_name_prefix
  n8n_domain           = var.n8n_domain

  n8n_license_key = var.n8n_license_key
  gcs_location    = var.gcs_location

  # Set true only if your creds have org-policy admin (see variable docs).
  manage_sa_key_org_policy = var.manage_sa_key_org_policy

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  gke_deletion_protection      = var.gke_deletion_protection
  postgres_deletion_protection = var.postgres_deletion_protection
  gcs_force_destroy            = var.gcs_force_destroy

  # DNS + TLS: manage the record in Cloud DNS, Google-managed cert.
  dns_managed_zone = var.dns_managed_zone
  tls_mode         = "google_managed"
}
