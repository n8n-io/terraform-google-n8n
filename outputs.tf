# ── App DNS ───────────────────────────────────────────────────────────────────

output "static_ip" {
  description = "Reserved global static IP of the module-managed L7 load balancer. Point n8n_fqdn (an A record) at this. The base module creates the record when cloud_dns_zone_name is set; otherwise create it in your DNS provider (as examples/cloudflare does). Null when create_ingress = false; the caller owns the load balancer and its address."
  value       = var.create_ingress ? google_compute_global_address.lb[0].address : null
}

output "n8n_url" {
  description = "URL to access n8n once DNS propagates and the cert is active"
  value       = "https://${local.n8n_fqdn}"
}

output "lb_ingress_ip" {
  description = "IP the module-managed Ingress reports once the LB is provisioned (should match static_ip). Null when create_ingress = false; the caller's own ingress reports its own address."
  value = var.create_ingress ? try(
    kubernetes_ingress_v1.n8n[0].status[0].load_balancer[0].ingress[0].ip,
    "LB not yet provisioned, run: kubectl get ingress n8n-ingress -n ${var.n8n_kube_namespace}"
  ) : null
}

# ── Secrets (retrieve with terraform output -raw <name>) ──────────────────────

output "n8n_encryption_key" {
  description = "n8n encryption key: the direct n8n_encryption_key when supplied, else the generated key. Back this up; losing it makes all stored credentials unreadable. Null when existing_n8n_core_secret_name supplies an existing core Secret; the module generates and reads no encryption key on that path."
  value       = local.effective_encryption_key
  sensitive   = true
}

output "n8n_database_password" {
  description = "Database password. Module-managed when create_postgres_instance = true, else the effective direct/Secret-reference value (null when supplied only via n8n_database_password_secret_ref, which the module never reads)."
  value       = var.create_postgres_instance ? random_password.db_password[0].result : var.n8n_database_password
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

# ── Infrastructure (ownership-neutral effective coordinates) ──────────────────
# Managed and customer-managed configurations return the same output names.
# Values are null when the underlying attribute does not exist on the
# selected path (e.g. no Cloud SQL connection_name for external PostgreSQL).

output "postgres_host" {
  description = "Effective PostgreSQL host: the module-managed Cloud SQL private IP, or the supplied external n8n_database_host."
  value       = local.effective_postgres_host
}

output "postgres_private_ip" {
  description = "Cloud SQL private IP (VPC-internal). Null when create_postgres_instance = false; use postgres_host or n8n_database_host instead."
  value       = var.create_postgres_instance ? google_sql_database_instance.n8n[0].private_ip_address : null
}

output "postgres_connection_name" {
  description = "Cloud SQL instance connection name (project:region:instance). Null when create_postgres_instance = false."
  value       = var.create_postgres_instance ? google_sql_database_instance.n8n[0].connection_name : null
}

output "postgres_kms_key_id" {
  description = "Effective Cloud KMS key ID protecting the module-managed Cloud SQL instance: the module-created key, the supplied existing_postgres_kms_key_id, or null for Google-managed encryption. Always null when create_postgres_instance = false."
  value       = var.create_postgres_instance ? local.effective_postgres_kms_key_id : null
}

output "redis_host" {
  description = "Effective Redis host: the module-managed Memorystore host, or the supplied external redis_host."
  value       = local.effective_redis_host
}

output "redis_port" {
  description = "Effective Redis port: 6379 for module-managed Memorystore, or the supplied external redis_port."
  value       = local.effective_redis_port
}

output "redis_tls_enabled" {
  description = "Whether the effective Redis connection uses TLS: redis_transit_encryption_enabled for module-managed Memorystore, or the supplied external redis_tls_enabled."
  value       = local.effective_redis_tls_enabled
}

output "redis_username" {
  description = "Effective external Redis ACL username (redis_username). Always null for module-managed Memorystore, which has no concept of one."
  value       = local.effective_redis_username
}

output "redis_kms_key_id" {
  description = "Effective Cloud KMS key ID protecting the module-managed Memorystore instance: the module-created key, the supplied existing_redis_kms_key_id, or null for Google-managed encryption. Always null when create_redis_instance = false."
  value       = var.create_redis_instance ? local.effective_redis_kms_key_id : null
}

output "redis_exporter_service_name" {
  description = "Kubernetes Service name exposing the opt-in Redis exporter's metrics port (9121), for a caller-managed ServiceMonitor or scrape config. Null when redis_exporter_enabled = false."
  value       = var.redis_exporter_enabled ? kubernetes_service_v1.redis_exporter[0].metadata[0].name : null
}

output "gcs_bucket_name" {
  description = "Effective GCS bucket used for n8n binary storage: module-created or the supplied existing_gcs_bucket_name."
  value       = local.effective_gcs_bucket_name
}

output "gcs_kms_key_id" {
  description = "Effective Cloud KMS key ID protecting the module-managed GCS bucket: the module-created key, the supplied existing_gcs_kms_key_id, or null for Google-managed encryption. Always null when create_gcs_bucket = false."
  value       = var.create_gcs_bucket ? local.effective_gcs_kms_key_id : null
}

output "gke_kms_key_id" {
  description = "Cloud KMS key ID the module configures for the module-managed GKE cluster's application-layer secrets encryption: the module-created key, or the supplied existing_gke_kms_key_id. Null when the module configures no key, which does not prove the cluster is unencrypted: a cluster encrypted before both inputs were cleared, or out of band, stays encrypted. Always null when create_gke = false."
  value       = var.create_gke ? local.effective_gke_kms_key_id : null
}

output "workload_identity_service_account" {
  description = "Google service account the n8n pods impersonate via Workload Identity."
  value       = google_service_account.n8n.email
}

output "workload_identity_pool" {
  description = "Effective Workload Identity pool the n8n Google service account is bound into (<project_id>.svc.id.goog, or existing_gke_workload_identity_pool for a cross-project existing cluster)."
  value       = local.effective_gke_workload_identity_pool
}

output "network_id" {
  description = "Effective network ID: the module-created VPC, or the supplied existing_network_name."
  value       = local.effective_network_id
}

output "subnetwork_self_link" {
  description = "Effective subnetwork self-link: the module-created subnet, or the supplied existing_subnetwork_name."
  value       = local.effective_subnetwork_self_link
}

# ── Cluster (wire the kubernetes/helm/kubectl providers in your root/example) ──

output "gke_cluster_name" {
  description = "Effective GKE cluster name: module-managed, or the supplied existing_gke_cluster_name."
  value       = local.effective_gke_cluster_name
}

output "gke_cluster_endpoint" {
  description = "Effective GKE control-plane endpoint. Pass to the kubernetes/helm providers as host (https://<endpoint>). Resolves to the module-managed cluster's endpoint, or to the existing cluster named by existing_gke_cluster_name."
  value       = local.effective_gke_cluster_endpoint
}

output "gke_cluster_ca_certificate" {
  description = "Effective base64-encoded GKE cluster CA. Pass to kubernetes/helm providers as cluster_ca_certificate (after base64decode). Resolves to the module-managed cluster's CA, or to the existing cluster named by existing_gke_cluster_name."
  value       = local.effective_gke_cluster_ca_certificate
  sensitive   = true
}

output "kubectl_config_command" {
  description = "Command to configure kubectl for this cluster."
  value       = "gcloud container clusters get-credentials ${local.effective_gke_cluster_name} --region ${var.gcp_region} --project ${var.project_id}"
}

output "n8n_kube_namespace" {
  description = "Kubernetes namespace n8n is deployed into."
  value       = local.effective_namespace
}

# ── Service and route contract (build a customer-managed ingress from these) ──

output "n8n_main_service_name" {
  description = "Kubernetes Service name that serves n8n's main UI/API traffic."
  value       = local.effective_main_service_name
}

output "n8n_webhook_service_name" {
  description = "Kubernetes Service name that serves n8n's webhook traffic."
  value       = local.effective_webhook_service_name
}

output "n8n_service_port" {
  description = "Port both the main and webhook Services listen on."
  value       = local.effective_service_port
}

output "n8n_main_route_prefixes" {
  description = "Path prefixes that must route to n8n_main_service_name."
  value       = local.effective_main_route_prefixes
}

output "n8n_webhook_route_prefixes" {
  description = "Path prefixes that must route to n8n_webhook_service_name: /webhook, /webhook-waiting, /form, /form-waiting, and /mcp."
  value       = local.effective_webhook_route_prefixes
}

output "n8n_ingress_hosts" {
  description = "Effective hostnames n8n serves the full main/webhook route set on: n8n_fqdn followed by every configured n8n_additional_domains entry, normalized to lowercase. Populated the same way regardless of create_ingress, so a customer-managed ingress can route the same hostnames the module would."
  value       = local.n8n_effective_ingress_hosts
}
