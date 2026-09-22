# ── Example: customer-managed-everything ───────────────────────────────────────
# Every ownership switch flipped to customer-managed: network, GKE, Cloud SQL,
# Redis, GCS bucket, namespace, ingress, HPAs, worker KEDA, and the KEDA
# controller install itself. This module call creates no VPC, GKE cluster,
# Cloud SQL instance, Memorystore instance, GCS bucket, Kubernetes namespace,
# ingress resources, HPAs, ScaledObjects, or KEDA release; every one of those
# is pre-existing infrastructure this example only references.
#
# See ../../docs/customer-managed-infrastructure.md for the full ownership
# matrix, every layer's required references, and the security boundary this
# implies. Database and Redis passwords, and the GCS HMAC secret, are supplied
# via existing Kubernetes Secret references, so none of them enter Terraform
# state; create every referenced Secret out of band before applying (see
# README.md).

module "n8n" {
  source = "../.."

  project_id             = var.project_id
  gcp_region             = var.gcp_region
  friendly_name_prefix   = var.friendly_name_prefix
  n8n_fqdn               = var.n8n_fqdn
  n8n_license_key        = var.n8n_license_key
  n8n_additional_domains = var.n8n_additional_domains

  # ── Network ownership: existing VPC + subnetwork ───────────────────────────
  create_network               = false
  existing_network_name        = var.existing_network_name
  existing_subnetwork_name     = var.existing_subnetwork_name
  existing_pods_range_name     = var.existing_pods_range_name
  existing_services_range_name = var.existing_services_range_name

  # ── Private Service Access ownership ───────────────────────────────────────
  # Not required here: create_postgres_instance and create_redis_instance are
  # both false below, so no module-managed data service needs a PSA
  # connection and existing_psa_prerequisites_attestation stays at its
  # default (false).
  create_psa = false

  # ── GKE ownership: existing regional cluster ───────────────────────────────
  create_gke                             = false
  existing_gke_cluster_name              = var.existing_gke_cluster_name
  existing_gke_prerequisites_attestation = var.existing_gke_prerequisites_attestation

  # ── PostgreSQL ownership: external database ────────────────────────────────
  create_postgres_instance = false
  n8n_database_host        = var.n8n_database_host
  n8n_database_password_secret_ref = {
    name = var.n8n_database_password_secret_name
  }

  # ── Redis ownership: external Redis-compatible service ─────────────────────
  create_redis_instance = false
  redis_host            = var.redis_host
  redis_tls_enabled     = var.redis_tls_enabled
  redis_password_secret_ref = {
    name = var.redis_password_secret_name
  }

  # ── GCS ownership: existing bucket + BYO HMAC identity ─────────────────────
  create_gcs_bucket              = false
  existing_gcs_bucket_name       = var.existing_gcs_bucket_name
  gcs_hmac_service_account_email = var.gcs_hmac_service_account_email
  gcs_hmac_access_id             = var.gcs_hmac_access_id
  gcs_hmac_secret_name           = var.gcs_hmac_secret_name

  # ── Namespace ownership: existing namespace ────────────────────────────────
  create_namespace   = false
  n8n_kube_namespace = var.n8n_kube_namespace

  # ── Ingress ownership: caller builds its own ingress from the route/service
  # outputs below ─────────────────────────────────────────────────────────────
  create_ingress = false

  # ── Autoscaling ownership: caller owns every scaler ────────────────────────
  n8n_main_hpa_enabled    = false
  n8n_main_fixed_replicas = var.n8n_main_fixed_replicas
  n8n_webhook_hpa_enabled = false
  n8n_worker_keda_enabled = false

  # ── Controller submodule ownership: caller already runs KEDA (unused here
  # since n8n_worker_keda_enabled = false, kept explicit for clarity) and the
  # pd-balanced StorageClass ─────────────────────────────────────────────────
  install_keda                     = false
  create_pd_balanced_storage_class = false
}
