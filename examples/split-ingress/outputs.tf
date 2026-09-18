output "public_ip" {
  description = "Global external static IP for the public webhook-only ingress. Point public_webhook_fqdn (an A record) at this."
  value       = google_compute_global_address.public.address
}

output "private_ip" {
  description = "Regional internal static IP for the private editor+webhook ingress. Point n8n_fqdn at this from a private DNS zone/resolver reachable by whoever administers n8n (VPN, interconnect, or a Cloud DNS private zone); this example creates no such DNS resource."
  value       = google_compute_address.private.address
}

output "n8n_editor_url" {
  description = "Private editor URL, reachable only through the internal ingress."
  value       = module.n8n.n8n_url
}

output "n8n_webhook_url" {
  description = "Public webhook base URL, reachable through the public ingress."
  value       = "https://${var.public_webhook_fqdn}"
}

output "kubectl_config_command" {
  value = module.n8n.kubectl_config_command
}

output "n8n_kube_namespace" {
  value = module.n8n.n8n_kube_namespace
}

# ── Ownership-neutral coordinates consumed by tests/scripts/smoke-test.sh ────
# The smoke test reads these from `terraform output` in this directory; without
# them its Redis, GCS, ingress-route, and additional-hostname checks are skipped.

output "redis_host" {
  description = "Effective Redis host (module-managed Memorystore or external)."
  value       = module.n8n.redis_host
}

output "redis_tls_enabled" {
  description = "Whether the effective Redis connection uses TLS."
  value       = module.n8n.redis_tls_enabled
}

output "redis_exporter_service_name" {
  description = "Redis exporter metrics Service name, or null when redis_exporter_enabled = false."
  value       = module.n8n.redis_exporter_service_name
}

output "gcs_bucket_name" {
  description = "Effective GCS bucket for n8n binary data."
  value       = module.n8n.gcs_bucket_name
}

output "n8n_main_service_name" {
  description = "Kubernetes Service serving n8n main UI/API traffic."
  value       = module.n8n.n8n_main_service_name
}

output "n8n_webhook_service_name" {
  description = "Kubernetes Service serving n8n webhook traffic."
  value       = module.n8n.n8n_webhook_service_name
}

output "n8n_service_port" {
  description = "Port the main and webhook Services listen on."
  value       = module.n8n.n8n_service_port
}

output "n8n_webhook_route_prefixes" {
  description = "Path prefixes that must route to the webhook Service."
  value       = module.n8n.n8n_webhook_route_prefixes
}

output "n8n_ingress_hosts" {
  description = "Effective hostnames n8n serves (n8n_fqdn plus n8n_additional_domains)."
  value       = module.n8n.n8n_ingress_hosts
}
