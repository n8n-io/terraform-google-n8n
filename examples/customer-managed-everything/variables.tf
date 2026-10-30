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

variable "n8n_main_fixed_replicas" {
  description = "Fixed replica count for n8n main pods, passed straight through to the module's own n8n_main_fixed_replicas (this example sets n8n_main_hpa_enabled=false, so the caller's own scaler manages main pods and this input only seeds the replica count). Defaults to the module's own default of 2 (multi-main). Set to 1 to run single-main queue mode instead; see the module's n8n_main_hpa_enabled description for the required license edition and maintenance implications."
  type        = number
  default     = 2
}

variable "n8n_additional_domains" {
  description = "Additional hostnames to give the full main/webhook route set alongside n8n_fqdn. Passed straight through to the module's n8n_additional_domains. Default empty (no aliases)."
  type        = list(string)
  default     = []
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

# ── TLS-inspecting / TLS-terminating proxy passthrough ─────────────────────
variable "n8n_extra_ca_pem" {
  description = "PEM-encoded CA certificate(s) every n8n role should trust for outbound TLS, for a TLS-inspecting egress proxy or a private CA. Passed straight through to the module's n8n_extra_ca_pem. Certificates only, no private keys. Null (the default) adds nothing. See https://github.com/n8n-io/terraform-google-n8n/blob/main/docs/tls-proxy.md."
  type        = string
  default     = null
}

variable "n8n_proxy_hops" {
  description = "Number of trusted reverse-proxy hops in front of n8n (N8N_PROXY_HOPS), passed through to the module's n8n_proxy_hops. This example creates no module-managed ingress, so count the hops on the ingress you run in front of the n8n Services. Express counts the immediate peer, then trusted X-Forwarded-For entries from right to left. A Google Cloud Application Load Balancer alone appends two entries and normally needs 2. Add 1 for each upstream proxy only when its entry survives downstream forwarding: an internal load balancer strips an incoming X-Forwarded-For, so the original client IP cannot be recovered behind it. Admit only the proxy's egress addresses on that ingress, or a client that bypasses the proxy can choose its own client IP. Null (the default) leaves n8n's own default. See https://github.com/n8n-io/terraform-google-n8n/blob/main/docs/tls-proxy.md."
  type        = number
  default     = null
}

variable "n8n_extra_env" {
  description = "Additional environment variables for the n8n container in every main, worker, and webhook-processor pod, passed straight through to the module's n8n_extra_env. Use it for HTTPS_PROXY, HTTP_PROXY and NO_PROXY behind an egress proxy (see https://github.com/n8n-io/terraform-google-n8n/blob/main/docs/tls-proxy.md). The module's input is meant for non-secret values, because values are stored in plain text in Terraform state and the Helm release. The documented exception is the credentials in an authenticated proxy URL. This example marks the variable sensitive to redact normal plan and apply output; values remain readable in Terraform state and the Helm release values."
  type = list(object({
    name  = string
    value = string
  }))
  default   = []
  sensitive = true
}
