# ── Example: Google-native split ingress (public webhooks / private editor) ───
# create_ingress = false: this example owns ingress, DNS, and TLS entirely
# (D9). The module still creates the VPC, GKE cluster, Cloud SQL, Memorystore,
# and GCS. Two hostnames split the public and private surface:
#
#   n8n_fqdn (var.n8n_fqdn)             -> private, internal HTTPS ingress only
#                                          (editor/API catch-all + webhook
#                                          families), reachable only through
#                                          the regional internal address.
#   public webhook host (var.public_webhook_fqdn) -> public, global HTTPS
#                                          ingress, webhook families only, no
#                                          editor/API route.
#
# n8n_webhook_url is pointed at the public host so WEBHOOK_URL/
# N8N_WEBHOOK_URL resolve externally while N8N_EDITOR_BASE_URL stays on the
# private host (task 19's split-host contract).
#
# This file plus network.tf/services.tf/tls.tf build the infrastructure the
# split ingress needs (task 21): addresses, proxy-only subnet, scoped
# firewall, exposure-specific Services/BackendConfigs, and TLS/DNS
# prerequisites. The actual kubernetes_ingress_v1 rules are added in task 22.

module "n8n" {
  source = "../.."

  project_id           = var.project_id
  gcp_region           = var.gcp_region
  friendly_name_prefix = var.friendly_name_prefix
  n8n_fqdn             = var.n8n_fqdn
  n8n_webhook_url      = "https://${var.public_webhook_fqdn}"

  n8n_license_key = var.n8n_license_key
  gcs_location    = var.gcs_location

  # Set true only if your creds have org-policy admin (see variable docs).
  manage_sa_key_org_policy = var.manage_sa_key_org_policy

  n8n_main_hpa_min_replicas = var.n8n_main_hpa_min_replicas

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  gke_deletion_protection      = var.gke_deletion_protection
  postgres_deletion_protection = var.postgres_deletion_protection
  gcs_force_destroy            = var.gcs_force_destroy

  # ── Backup tuning passthrough ────────────────────────────────────────────
  postgres_backup_retained_backups        = var.postgres_backup_retained_backups
  postgres_transaction_log_retention_days = var.postgres_transaction_log_retention_days

  # This example owns ingress, DNS, and TLS entirely (network.tf, services.tf,
  # tls.tf); leave every managed-ingress tuning input at its default so
  # checks.tf's create_ingress = false guard stays quiet.
  create_ingress = false
}
