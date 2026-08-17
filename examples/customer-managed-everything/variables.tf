variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "gcp_region" {
  description = "GCP region of the existing network, GKE cluster, and Redis/PostgreSQL/GCS resources (e.g. us-east4, us-east1, europe-west1)."
  type        = string
  default     = "us-east4"
}

variable "friendly_name_prefix" {
  description = "Prefix used to derive the name of any resource the module still creates (Workload Identity service account, generated Secrets, n8n Helm release)."
  type        = string
  default     = "dev"
}

variable "n8n_fqdn" {
  description = "Hostname n8n is served on. Point your own DNS/ingress at whatever address it resolves to; this example does not manage DNS or ingress."
  type        = string
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key (multi-main requires Enterprise)."
  type        = string
  sensitive   = true
}

# ── Network ────────────────────────────────────────────────────────────────

variable "existing_network_name" {
  description = "Name of the existing VPC network GKE and data services attach to."
  type        = string
}

variable "existing_subnetwork_name" {
  description = "Name of the existing subnetwork (in gcp_region) GKE and data services attach to."
  type        = string
}

variable "existing_pods_range_name" {
  description = "Name of the existing secondary IP range on existing_subnetwork_name used for GKE pod alias IPs."
  type        = string
}

variable "existing_services_range_name" {
  description = "Name of the existing secondary IP range on existing_subnetwork_name used for GKE service alias IPs."
  type        = string
}

# ── GKE ────────────────────────────────────────────────────────────────────

variable "existing_gke_cluster_name" {
  description = "Name of the existing regional GKE cluster (in gcp_region) to deploy n8n onto. See README.md for the required cluster properties."
  type        = string
}

variable "existing_gke_prerequisites_attestation" {
  description = "Explicit confirmation that existing_gke_cluster_name is reachable by the providers configured in providers.tf, uses VPC-native networking, has Workload Identity enabled, runs GKE's native ingress/metrics/autoscaling/PD CSI controllers, has capacity for the requested n8n workload, and grants this deployment permission to create namespaced resources. No default: set it to true only after confirming these against your own cluster (see README.md)."
  type        = bool
}

# ── PostgreSQL ─────────────────────────────────────────────────────────────

variable "n8n_database_host" {
  description = "External PostgreSQL host reachable from existing_network_name."
  type        = string
}

variable "n8n_database_password_secret_name" {
  description = "Name of an existing Kubernetes Secret (in n8n_kube_namespace) holding the external database password under key \"password\". Create this Secret out of band before applying; the module never reads its value."
  type        = string
}

# ── Redis ──────────────────────────────────────────────────────────────────

variable "redis_host" {
  description = "External Redis-compatible host n8n and KEDA connect to."
  type        = string
}

variable "redis_tls_enabled" {
  description = "Whether n8n and KEDA connect to redis_host over TLS."
  type        = bool
  default     = false
}

variable "redis_password_secret_name" {
  description = "Name of an existing Kubernetes Secret (in n8n_kube_namespace) holding the external Redis password under key \"password\". Create this Secret out of band before applying; the module never reads its value."
  type        = string
}

# ── GCS ────────────────────────────────────────────────────────────────────

variable "existing_gcs_bucket_name" {
  description = "Name of the existing GCS bucket used for n8n binary storage."
  type        = string
}

variable "gcs_hmac_service_account_email" {
  description = "Email of the pre-existing service account that owns the out-of-band-created HMAC key. The module grants this account objectAdmin on existing_gcs_bucket_name; it does not create the account or the key."
  type        = string
}

variable "gcs_hmac_access_id" {
  description = "HMAC access ID (S3 access key) for the pre-existing key named by gcs_hmac_service_account_email."
  type        = string
}

variable "gcs_hmac_secret_name" {
  description = "Name of an existing Kubernetes Secret (in n8n_kube_namespace) holding the HMAC secret under key \"accessSecret\". Create this Secret out of band before applying; the module never reads its value."
  type        = string
}

# ── Namespace ──────────────────────────────────────────────────────────────

variable "n8n_kube_namespace" {
  description = "Name of the existing Kubernetes namespace to deploy n8n into. Create it out of band before applying."
  type        = string
  default     = "n8n"
}
