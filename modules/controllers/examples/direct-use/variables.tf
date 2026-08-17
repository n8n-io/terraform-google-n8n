variable "project_id" {
  description = "GCP project ID that owns the existing GKE cluster."
  type        = string
}

variable "gcp_region" {
  description = "GCP region of the existing regional GKE cluster."
  type        = string
  default     = "us-east4"
}

variable "gke_cluster_name" {
  description = "Name of the existing regional GKE cluster to install KEDA onto."
  type        = string
}

variable "n8n_fqdn" {
  description = "Hostname the separately managed n8n Helm release is served on."
  type        = string
}
