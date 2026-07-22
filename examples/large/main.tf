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

  project_id   = var.project_id
  gcp_region   = var.gcp_region
  cluster_name = var.cluster_name
  n8n_domain   = var.n8n_domain

  n8n_license_key = var.n8n_license_key
  gcs_location    = var.gcs_location

  # Set true only if your creds have org-policy admin (see variable docs).
  manage_sa_key_org_policy = var.manage_sa_key_org_policy

  # ── Sizing (large) ──────────────────────────────────────────────────────────
  cloudsql_tier              = var.cloudsql_tier
  cloudsql_disk_size         = var.cloudsql_disk_size
  cloudsql_availability_type = var.cloudsql_availability_type

  memorystore_tier      = var.memorystore_tier
  memorystore_memory_gb = var.memorystore_memory_gb

  node_machine_type = var.node_machine_type
  node_min_per_zone = var.node_min_per_zone
  node_max_per_zone = var.node_max_per_zone

  n8n_worker_concurrency       = var.n8n_worker_concurrency
  n8n_worker_keda_min_replicas = var.n8n_worker_keda_min_replicas
  n8n_worker_keda_max_replicas = var.n8n_worker_keda_max_replicas
  n8n_main_hpa_min_replicas    = var.n8n_main_hpa_min_replicas
  n8n_webhook_hpa_min_replicas = var.n8n_webhook_hpa_min_replicas
  n8n_webhook_hpa_max_replicas = var.n8n_webhook_hpa_max_replicas

  n8n_execution_concurrency_limit = var.n8n_execution_concurrency_limit

  # Teardown controls (safe defaults; flip to allow `terraform destroy`).
  cluster_deletion_protection  = var.cluster_deletion_protection
  cloudsql_deletion_protection = var.cloudsql_deletion_protection
  gcs_force_destroy            = var.gcs_force_destroy

  # DNS + TLS: manage the record in Cloud DNS, Google-managed cert.
  dns_managed_zone = var.dns_managed_zone
  tls_mode         = "google_managed"
}
