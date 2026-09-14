# ── Example: large (Google Cloud DNS + Google-managed TLS, large sizing) ──────
# Same substrate as examples/small (the module creates the VPC, GKE cluster,
# Cloud SQL, Memorystore, GCS, and manages the Cloud DNS A-record), sized for
# high throughput: larger HA Cloud SQL + Memorystore, 16-vCPU nodes, high
# autoscaling ceilings. Sizing is NOT scale-validated on GKE; tune
# against a load test.
#
# NOTE: google_managed TLS is validated end to end (cert issued, HTTPS reachable);
# the DNS A-record must point at the LB static IP before the cert provisions.
# examples/cloudflare (Let's Encrypt) is an alternative; the sizing vars below
# apply there too.

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

  # ── Sizing (large) ──────────────────────────────────────────────────────────
  postgres_machine_type      = var.postgres_machine_type
  postgres_disk_size         = var.postgres_disk_size
  postgres_availability_type = var.postgres_availability_type

  redis_tier                     = var.redis_tier
  redis_memory_size_gb           = var.redis_memory_size_gb
  n8n_redis_timeout_threshold_ms = var.n8n_redis_timeout_threshold_ms

  gke_node_type         = var.gke_node_type
  gke_node_min_per_zone = var.gke_node_min_per_zone
  gke_node_max_per_zone = var.gke_node_max_per_zone
  gke_node_disk_size_gb = var.gke_node_disk_size_gb
  gke_node_disk_type    = var.gke_node_disk_type

  db_postgresdb_pool_size = var.db_postgresdb_pool_size

  n8n_worker_concurrency       = var.n8n_worker_concurrency
  n8n_worker_keda_min_replicas = var.n8n_worker_keda_min_replicas
  n8n_worker_keda_max_replicas = var.n8n_worker_keda_max_replicas
  n8n_main_hpa_min_replicas    = var.n8n_main_hpa_min_replicas
  n8n_webhook_hpa_min_replicas = var.n8n_webhook_hpa_min_replicas
  n8n_webhook_hpa_max_replicas = var.n8n_webhook_hpa_max_replicas

  n8n_execution_concurrency_limit = var.n8n_execution_concurrency_limit

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  gke_deletion_protection      = var.gke_deletion_protection
  postgres_deletion_protection = var.postgres_deletion_protection
  gcs_force_destroy            = var.gcs_force_destroy

  # DNS + TLS: manage the record in Cloud DNS, Google-managed cert.
  cloud_dns_zone_name = var.cloud_dns_zone_name
  tls_mode            = "google_managed"
}
