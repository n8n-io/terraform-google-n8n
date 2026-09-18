# ── Example: customer-managed-redis ────────────────────────────────────────────
# Redis ownership boundary only: the module points n8n and KEDA at an external
# Redis-compatible service instead of creating Memorystore. Every other layer
# (VPC, GKE, Cloud SQL, GCS, ingress, DNS) stays module-managed, same as
# examples/small.
#
# The password is supplied via an existing Kubernetes Secret reference
# (redis_password_secret_ref), so it never enters Terraform state; create that
# Secret out of band before applying (see README.md).

module "n8n" {
  source = "../.."

  project_id           = var.project_id
  gcp_region           = var.gcp_region
  friendly_name_prefix = var.friendly_name_prefix
  n8n_fqdn             = var.n8n_fqdn

  n8n_license_key = var.n8n_license_key
  gcs_location    = var.gcs_location

  manage_sa_key_org_policy = var.manage_sa_key_org_policy

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  # ── Redis ownership: external Redis-compatible service ─────────────────────
  create_redis_instance = false
  redis_host            = var.redis_host
  redis_port            = var.redis_port
  redis_tls_enabled     = var.redis_tls_enabled
  redis_username        = var.redis_username
  redis_password_secret_ref = {
    name = var.redis_password_secret_name
  }

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  gke_deletion_protection      = var.gke_deletion_protection
  postgres_deletion_protection = var.postgres_deletion_protection
  gcs_force_destroy            = var.gcs_force_destroy

  # DNS + TLS: manage the record in Cloud DNS, Google-managed cert.
  cloud_dns_zone_name = var.cloud_dns_zone_name
  tls_mode            = "google_managed"
}
