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
