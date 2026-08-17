output "static_ip" {
  description = "LB static IP. Point n8n_fqdn at this if you are not letting the module manage Cloud DNS."
  value       = module.n8n.static_ip
}

output "n8n_url" {
  value = module.n8n.n8n_url
}

output "kubectl_config_command" {
  value = module.n8n.kubectl_config_command
}

output "n8n_kube_namespace" {
  value = module.n8n.n8n_kube_namespace
}

output "redis_host" {
  description = "Effective Redis host; should equal var.redis_host."
  value       = module.n8n.redis_host
}

output "redis_tls_enabled" {
  description = "Effective Redis TLS setting; should equal var.redis_tls_enabled."
  value       = module.n8n.redis_tls_enabled
}
