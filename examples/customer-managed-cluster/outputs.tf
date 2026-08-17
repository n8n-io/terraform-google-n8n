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

output "gke_cluster_name" {
  description = "Effective GKE cluster name; should equal existing_gke_cluster_name."
  value       = module.n8n.gke_cluster_name
}
