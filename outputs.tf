# ── App DNS ───────────────────────────────────────────────────────────────────

output "static_ip" {
  description = "Reserved global static IP of the L7 load balancer. Point n8n_domain (an A record) at this. The base module creates the record when dns_managed_zone is set; otherwise create it in your DNS provider (as examples/cloudflare does)."
  value       = google_compute_global_address.lb.address
}

output "n8n_url" {
  description = "URL to access n8n once DNS propagates and the cert is active"
  value       = "https://${local.n8n_domain}"
}

output "lb_ingress_ip" {
  description = "IP the Ingress reports once the LB is provisioned (should match static_ip)."
  value = try(
    kubernetes_ingress_v1.n8n.status[0].load_balancer[0].ingress[0].ip,
    "LB not yet provisioned, run: kubectl get ingress n8n-ingress -n ${var.namespace}"
  )
}

# ── Secrets (retrieve with terraform output -raw <name>) ──────────────────────

output "n8n_encryption_key" {
  description = "n8n encryption key. Back this up; losing it makes all stored credentials unreadable."
  value       = random_id.n8n_encryption_key.hex
  sensitive   = true
}

output "db_password" {
  description = "Database password. Module-managed when create_database = true, else var.db_password."
  value       = var.create_database ? random_password.db_password.result : var.db_password
  sensitive   = true
}

output "gcs_hmac_access_id" {
  description = "GCS HMAC access key ID for the n8n S3-compatible binary storage driver (module-created or caller-supplied in BYO mode)."
  value       = local.hmac_access_id
  sensitive   = true
}

output "gcs_hmac_secret" {
  description = "GCS HMAC secret for the n8n S3-compatible binary storage driver. Null in BYO mode when supplied via an existing Secret (gcs_hmac_secret_name)."
  value       = local.s3_secret_value
  sensitive   = true
}

# ── Infrastructure ─────────────────────────────────────────────────────────────

output "cloudsql_private_ip" {
  description = "Cloud SQL private IP (VPC-internal)."
  value       = google_sql_database_instance.n8n.private_ip_address
}

output "cloudsql_connection_name" {
  description = "Cloud SQL instance connection name (project:region:instance)."
  value       = google_sql_database_instance.n8n.connection_name
}

output "memorystore_host" {
  description = "Memorystore Redis host (VPC-internal)."
  value       = google_redis_instance.n8n.host
}

output "gcs_bucket_name" {
  description = "GCS bucket used for n8n binary storage."
  value       = google_storage_bucket.n8n.name
}

output "workload_identity_service_account" {
  description = "Google service account the n8n pods impersonate via Workload Identity."
  value       = google_service_account.n8n.email
}

# ── Cluster (wire the kubernetes/helm/kubectl providers in your root/example) ──

output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.n8n.name
}

output "cluster_endpoint" {
  description = "GKE control-plane endpoint. Pass to the kubernetes/helm providers as host (https://<endpoint>)."
  value       = google_container_cluster.n8n.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded GKE cluster CA. Pass to kubernetes/helm providers as cluster_ca_certificate (after base64decode)."
  value       = try(google_container_cluster.n8n.master_auth[0].cluster_ca_certificate, null)
  sensitive   = true
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.n8n.name} --region ${var.gcp_region} --project ${var.project_id}"
}

output "namespace" {
  description = "Kubernetes namespace n8n is deployed into."
  value       = var.namespace
}
