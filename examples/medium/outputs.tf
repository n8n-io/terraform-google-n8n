output "static_ip" {
  description = "LB static IP. Point n8n_domain at this if you are not letting the module manage Cloud DNS."
  value       = module.n8n.static_ip
}

output "n8n_url" {
  value = module.n8n.n8n_url
}

output "kubectl_config_command" {
  value = module.n8n.kubectl_config_command
}

output "namespace" {
  value = module.n8n.namespace
}
