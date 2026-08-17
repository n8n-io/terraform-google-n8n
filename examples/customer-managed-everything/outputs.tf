output "n8n_url" {
  value = module.n8n.n8n_url
}

output "kubectl_config_command" {
  value = module.n8n.kubectl_config_command
}

output "n8n_kube_namespace" {
  description = "Effective namespace; should equal var.n8n_kube_namespace."
  value       = module.n8n.n8n_kube_namespace
}

output "gke_cluster_name" {
  description = "Effective GKE cluster name; should equal var.existing_gke_cluster_name."
  value       = module.n8n.gke_cluster_name
}

output "network_id" {
  description = "Effective network ID; should resolve to var.existing_network_name."
  value       = module.n8n.network_id
}

output "postgres_host" {
  description = "Effective PostgreSQL host; should equal var.n8n_database_host."
  value       = module.n8n.postgres_host
}

output "redis_host" {
  description = "Effective Redis host; should equal var.redis_host."
  value       = module.n8n.redis_host
}

output "gcs_bucket_name" {
  description = "Effective GCS bucket; should equal var.existing_gcs_bucket_name."
  value       = module.n8n.gcs_bucket_name
}

# ── Service and route contract: build your own ingress from these ────────────

output "n8n_main_service_name" {
  value = module.n8n.n8n_main_service_name
}

output "n8n_webhook_service_name" {
  value = module.n8n.n8n_webhook_service_name
}

output "n8n_service_port" {
  value = module.n8n.n8n_service_port
}

output "n8n_main_route_prefixes" {
  value = module.n8n.n8n_main_route_prefixes
}

output "n8n_webhook_route_prefixes" {
  value = module.n8n.n8n_webhook_route_prefixes
}
