output "static_ip" {
  description = "LB static IP. Point n8n_fqdn at this if you are not letting the module manage Cloud DNS."
  value       = module.n8n.static_ip
}

output "n8n_url" {
  description = "HTTPS URL of the n8n editor."
  value       = module.n8n.n8n_url
}

output "kubectl_config_command" {
  description = "gcloud command that writes kubeconfig credentials for the GKE cluster."
  value       = module.n8n.kubectl_config_command
}

output "n8n_kube_namespace" {
  description = "Kubernetes namespace n8n is deployed into. Read by tests/scripts/verify-worker-pools.sh."
  value       = module.n8n.n8n_kube_namespace
}

output "worker_pool_names" {
  description = "Names of the worker pools this example declares, in declaration order. Read by tests/scripts/verify-worker-pools.sh, which counts the rendered pool Deployments and ScaledObjects against this list: the chart-predates-pools failure leaves this list non-empty and the cluster with nothing behind it, and only a live count can see that."
  value       = [for p in local.worker_pools : p.name]
}

# ── Ownership-neutral coordinates consumed by tests/scripts/smoke-test.sh ────

output "redis_host" {
  description = "Effective Redis host (module-managed Memorystore or external)."
  value       = module.n8n.redis_host
}

output "redis_tls_enabled" {
  description = "Whether the effective Redis connection uses TLS."
  value       = module.n8n.redis_tls_enabled
}

# ── Secrets ───────────────────────────────────────────────────────────────────
# Retrieve with: terraform output -raw <name>

output "n8n_encryption_key" {
  description = "n8n encryption key. Back this up in a password manager."
  value       = module.n8n.n8n_encryption_key
  sensitive   = true
}

output "n8n_database_password" {
  description = "Cloud SQL PostgreSQL password. Back this up in a password manager."
  value       = module.n8n.n8n_database_password
  sensitive   = true
}
