# GCP substrate variables
#
# GCP inputs for the module. Shared, provider-agnostic inputs live in
# variables.tf.

variable "project_id" {
  description = "GCP project ID to deploy into."
  type        = string
}

variable "gcp_region" {
  description = "GCP region for regional resources (GKE, Cloud SQL, Memorystore, subnet)."
  type        = string
  default     = "europe-west1"
}

# ── Networking (VPC-native) ───────────────────────────────────────────────────

variable "subnet_cidr" {
  description = "Primary CIDR for the node subnet."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "Secondary range for GKE pods (VPC-native / alias IPs)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "services_cidr" {
  description = "Secondary range for GKE services (VPC-native / alias IPs)."
  type        = string
  default     = "10.30.0.0/20"
}

variable "psa_prefix_length" {
  description = "Prefix length for the Private Services Access range that Cloud SQL / Memorystore peer into."
  type        = number
  default     = 16
}

# ── Cloud SQL ─────────────────────────────────────────────────────────────────

variable "cloudsql_database_version" {
  description = "Cloud SQL Postgres version."
  type        = string
  default     = "POSTGRES_16"
}

variable "cloudsql_edition" {
  description = "Cloud SQL edition. ENTERPRISE supports shared-core/legacy tiers like db-g1-small (cheap, dev). ENTERPRISE_PLUS requires db-perf-optimized-N-* tiers. Pinned because some projects/orgs default new instances to ENTERPRISE_PLUS, which rejects db-g1-small."
  type        = string
  default     = "ENTERPRISE"

  validation {
    condition     = contains(["ENTERPRISE", "ENTERPRISE_PLUS"], var.cloudsql_edition)
    error_message = "cloudsql_edition must be ENTERPRISE or ENTERPRISE_PLUS."
  }
}

variable "cloudsql_tier" {
  description = "Cloud SQL machine tier. ENTERPRISE: e.g. db-g1-small, db-custom-2-7680. ENTERPRISE_PLUS: e.g. db-perf-optimized-N-2. Must be compatible with cloudsql_edition."
  type        = string
  default     = "db-g1-small"
}

variable "cloudsql_availability_type" {
  description = "REGIONAL for HA (failover replica), ZONAL for single-zone."
  type        = string
  default     = "REGIONAL"
}

variable "cloudsql_disk_size" {
  description = "Cloud SQL data disk size in GB."
  type        = number
  default     = 50
}

variable "cloudsql_deletion_protection" {
  description = "Block terraform destroy of the Cloud SQL instance."
  type        = bool
  default     = true
}

variable "db_name" {
  description = "n8n database name."
  type        = string
  default     = "n8n_enterprise"
}

variable "db_username" {
  description = "n8n database user."
  type        = string
  default     = "n8n"
}

# ── Memorystore ───────────────────────────────────────────────────────────────

variable "memorystore_tier" {
  description = "Memorystore tier: BASIC (no replica) or STANDARD_HA."
  type        = string
  default     = "BASIC"
}

variable "memorystore_memory_gb" {
  description = "Memorystore capacity in GB."
  type        = number
  default     = 1
}

variable "memorystore_redis_version" {
  description = "Memorystore Redis version."
  type        = string
  default     = "REDIS_7_2"
}

variable "memorystore_auth_enabled" {
  description = "Enable Redis AUTH. If true, the KEDA worker trigger needs a TriggerAuthentication CRD."
  type        = bool
  default     = false
}

# ── GCS binary storage ────────────────────────────────────────────────────────

variable "gcs_location" {
  description = "GCS bucket location (region or multi-region)."
  type        = string
  default     = "EU"
}

variable "gcs_force_destroy" {
  description = "Allow terraform destroy to delete a non-empty bucket (dev only)."
  type        = bool
  default     = false
}

variable "manage_sa_key_org_policy" {
  description = <<-EOT
    Opt-in: let this module set a PROJECT-LEVEL override that turns OFF the
    iam.disableServiceAccountKeyCreation org policy, so the GCS HMAC key can be
    created. Default false, the module does not touch org policy.
    Set true ONLY IF: (a) your credentials have roles/orgpolicy.policyAdmin (org/
    folder-level; a normal project deployer does not), and (b) your org permits
    overriding this guardrail. Otherwise disable the policy out-of-band and leave
    this false. Requires the orgpolicy.googleapis.com API enabled.
  EOT
  type        = bool
  default     = false
}

# ── BYO / pre-existing HMAC key ───────────────────────────────────────────────
# For orgs that cannot relax iam.disableServiceAccountKeyCreation at all: create
# the service account + HMAC key out of band and pass them in here, so the module
# never calls google_storage_hmac_key. Leave these empty for the default path
# (module creates the SA and key itself). When set, the module grants the
# supplied service account access to the module-created bucket.

variable "gcs_hmac_service_account_email" {
  description = <<-EOT
    BYO HMAC mode: email of a PRE-EXISTING service account that owns an
    out-of-band-created HMAC key. When set, the module does NOT create the storage
    service account or the HMAC key; it grants this SA objectAdmin on the bucket
    and wires the credentials below into n8n. Requires gcs_hmac_access_id and
    either gcs_hmac_secret or gcs_hmac_secret_name. Empty = default (module
    creates the key).
  EOT
  type        = string
  default     = ""
}

variable "gcs_hmac_access_id" {
  description = "BYO HMAC mode: the HMAC access ID (S3 access key) for the pre-existing key. Required when gcs_hmac_service_account_email is set."
  type        = string
  default     = ""

  # Required in BYO mode (or n8n gets an empty S3 access key), meaningless
  # outside it (the module-created key supplies its own access ID).
  validation {
    condition     = (var.gcs_hmac_service_account_email == "") == (var.gcs_hmac_access_id == "")
    error_message = "gcs_hmac_access_id is required when gcs_hmac_service_account_email is set (BYO HMAC mode), and must be empty otherwise."
  }

  # BYO mode must also come with a usable secret; failing the plan here (not
  # at a check warning) prevents an apply that deploys n8n with broken S3
  # credentials. The rule keys off gcs_hmac_access_id (which the validation
  # above ties to BYO mode) rather than off gcs_hmac_service_account_email,
  # so the cross-variable validation references stay acyclic (the secret
  # inputs already reference the email) and the condition tests its own
  # variable as Terraform requires.
  validation {
    condition = var.gcs_hmac_access_id == "" || (
      var.gcs_hmac_secret != "" || var.gcs_hmac_secret_name != ""
    )
    error_message = "gcs_hmac_access_id is set (BYO HMAC mode), so either gcs_hmac_secret or gcs_hmac_secret_name is also required."
  }
}

variable "gcs_hmac_secret" {
  description = "BYO HMAC mode: the HMAC secret (S3 secret access key). The module wraps it in the n8n-s3-secret Kubernetes Secret. Ignored if gcs_hmac_secret_name is set. Prefer gcs_hmac_secret_name to keep the raw secret out of Terraform state."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = var.gcs_hmac_secret == "" || var.gcs_hmac_service_account_email != ""
    error_message = "gcs_hmac_secret is only used in BYO HMAC mode; set gcs_hmac_service_account_email as well, or leave gcs_hmac_secret empty (the module-created key supplies its own secret)."
  }
}

variable "gcs_hmac_secret_name" {
  description = "BYO HMAC mode (most locked-down): name of an EXISTING Kubernetes Secret in the n8n namespace holding the HMAC secret under key 'accessSecret'. When set, the module references it directly and creates no Secret, so the raw secret never enters Terraform state. Overrides gcs_hmac_secret."
  type        = string
  default     = ""

  # Outside BYO mode the module creates its own HMAC key, whose secret could
  # never match an externally supplied Secret; reject the combination.
  validation {
    condition     = var.gcs_hmac_secret_name == "" || var.gcs_hmac_service_account_email != ""
    error_message = "gcs_hmac_secret_name is only used in BYO HMAC mode; the module-created HMAC key's secret would not match an external Secret. Set gcs_hmac_service_account_email as well, or leave gcs_hmac_secret_name empty."
  }
}

# ── Workload Identity ─────────────────────────────────────────────────────────

variable "k8s_service_account_name" {
  description = "Kubernetes ServiceAccount the n8n pods run as (annotated for Workload Identity). Matches the n8n Helm chart's serviceAccount name."
  type        = string
  default     = "n8n"
}

# ── TLS ───────────────────────────────────────────────────────────────────────
# The native gce Ingress terminates TLS at the Google Cloud L7 LB, so the cert
# must be presentable to that LB. tls_mode selects how, using ONLY GCP-native or
# BYO mechanisms so the base module needs no third-party provider. Automated
# Let's Encrypt (which needs a DNS-01 solver) is delivered by examples/cloudflare,
# which populates a k8s TLS Secret and sets tls_mode = "secret".

variable "tls_mode" {
  description = <<-EOT
    How the LB gets its cert (base module, provider-clean):
      - "google_managed" : ManagedCertificate CRD, auto-renew. DEFAULT. Validated end to end; the DNS A-record must point at the LB static IP before the cert can provision.
      - "custom"         : bring your own PEM (tls_cert_pem/tls_key_pem), e.g. a Cloudflare Origin CA cert, uploaded as a pre-shared cert.
      - "secret"         : the gce Ingress consumes an existing k8s TLS Secret (tls_secret_name). This is how examples/cloudflare wires Let's Encrypt via cert-manager.
      - "self_signed"    : instant cert with a browser warning, for smoke tests before DNS is live.
  EOT
  type        = string
  default     = "google_managed"

  validation {
    condition     = contains(["google_managed", "custom", "secret", "self_signed"], var.tls_mode)
    error_message = "tls_mode must be one of: google_managed, custom, secret, self_signed."
  }
}

variable "tls_cert_pem" {
  description = "PEM certificate chain (tls_mode = custom), e.g. a Cloudflare Origin CA cert."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_key_pem" {
  description = "PEM private key (tls_mode = custom)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "tls_secret_name" {
  description = "Name of an existing Kubernetes TLS Secret the Ingress should use (tls_mode = secret). Populated by an external issuer such as cert-manager in examples/cloudflare."
  type        = string
  default     = "n8n-tls"
}

variable "https_redirect" {
  description = "Redirect HTTP->HTTPS at the LB via a FrontendConfig. Set false while a google_managed cert is still provisioning (Google needs HTTP reachable), then flip true."
  type        = bool
  default     = true
}

# ── DNS (Google Cloud DNS , base/default path) ────────────────────────────────
# The base module manages the record in Google Cloud DNS (the small/default
# example). Alternative DNS providers are examples that manage their own record
# against the module's static IP output (examples/cloudflare, examples/godaddy).

variable "dns_managed_zone" {
  description = "Google Cloud DNS managed-zone name to create the A record in. Empty string means the module does not manage DNS (you point n8n_domain at the static IP output yourself, as examples/cloudflare does)."
  type        = string
  default     = ""
}

# ── GKE cluster + node pool ───────────────────────────────────────────────────

variable "gke_release_channel" {
  description = "GKE release channel: RAPID, REGULAR, STABLE, or UNSPECIFIED (to pin a version)."
  type        = string
  default     = "REGULAR"
}

variable "gke_min_master_version" {
  description = "Optional control-plane version prefix (e.g. \"1.32\"). Empty lets the release channel decide."
  type        = string
  default     = ""
}

variable "cluster_deletion_protection" {
  description = "Block terraform destroy of the GKE cluster (google provider default is true)."
  type        = bool
  default     = true
}

variable "enable_private_nodes" {
  description = "Give nodes private IPs only (egress via Cloud NAT). Control-plane endpoint stays public unless locked down via master_authorized_networks."
  type        = bool
  default     = true
}

variable "master_ipv4_cidr" {
  description = "CIDR for the GKE control-plane peering range (private cluster). Must not overlap the subnet/pods/services ranges."
  type        = string
  default     = "172.16.0.0/28"
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the control-plane endpoint. Empty = open (dev only); set to your admin CIDRs for a locked-down control plane."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "node_machine_type" {
  description = "Node machine type."
  type        = string
  default     = "e2-standard-4"
}

variable "node_min_per_zone" {
  description = "Autoscaling minimum nodes PER ZONE. A regional cluster spans ~3 zones, so total min is roughly this x3."
  type        = number
  default     = 1
}

variable "node_max_per_zone" {
  description = "Autoscaling maximum nodes PER ZONE (total max is roughly this x number of zones)."
  type        = number
  default     = 2
}

variable "node_disk_size_gb" {
  description = "Node boot disk size in GB."
  type        = number
  default     = 100
}

variable "node_disk_type" {
  description = "Node boot disk type (pd-standard, pd-balanced, pd-ssd)."
  type        = string
  default     = "pd-balanced"
}

variable "psa_cleanup_destroy_duration" {
  description = "How long to pause on destroy after Cloud SQL/Memorystore are deleted before deleting the Private Services Access peering, giving GCP's backend time to release its hold on the connection. GCP does not report when the release completes, and the observed lag varies widely (minutes to well over an hour). If destroy still fails with 'Producer services ... are still using this connection', either raise this or use the compute-level peering-delete escape hatch documented in README.md ('Teardown'). Accepts Go duration syntax (e.g. \"3m\", \"15m\", \"1h\")."
  type        = string
  default     = "3m"
}
