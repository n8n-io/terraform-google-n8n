output "static_ip" {
  description = "LB static IP that the GoDaddy A-record points at."
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
