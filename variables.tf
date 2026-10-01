# ── Foundation inputs ─────────────────────────────────────────────────────────
# Resource naming (friendly_name_prefix), the n8n FQDN, and the core n8n
# inputs. The GCP substrate
# (VPC, GKE, Cloud SQL, Memorystore, GCS) is created by the module from the
# inputs in variables_gcp.tf; see examples/small/.

variable "friendly_name_prefix" {
  description = "Prefix used to derive the name of every Google Cloud resource the module creates (e.g. <friendly_name_prefix>-n8n for the GKE cluster, <friendly_name_prefix>-n8n-pg for Cloud SQL). Most commonly an environment (e.g. \"sandbox\", \"prod\"), team, or project name."
  type        = string

  validation {
    condition     = !strcontains(var.friendly_name_prefix, "n8n")
    error_message = "friendly_name_prefix must not contain 'n8n' - the module already appends it, and including it here produces redundant names like <prefix>-n8n-n8n-pg."
  }

  # GCP resource names are RFC1035: fail at plan time instead of mid-apply.
  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]*[a-z0-9])?$", var.friendly_name_prefix))
    error_message = "friendly_name_prefix must start with a lowercase letter and contain only lowercase letters, digits, and hyphens (no trailing hyphen), per GCP resource naming rules."
  }

  # The tightest limit that derives from this prefix is the Google service
  # account account_id (30 characters): <friendly_name_prefix>-n8n-nodes and
  # <friendly_name_prefix>-n8n-store append 10 characters, leaving 20 for the
  # prefix itself. Memorystore (40-character instance ID, "-n8n-redis" suffix)
  # and GKE names (40 characters, shorter suffixes) are looser and never bind
  # first. The substr() guards on the account_id arguments are belt and
  # braces; this validator must keep them unreachable, because truncation
  # would collide the SA ids or leave a trailing hyphen.
  validation {
    condition     = length(var.friendly_name_prefix) <= 20
    error_message = "friendly_name_prefix must be 20 characters or fewer so derived service-account IDs (<friendly_name_prefix>-n8n-nodes/-store) stay within Google Cloud's 30-character account_id limit."
  }
}

variable "common_labels" {
  description = "Common labels merged into every taggable Google Cloud resource the module creates. Built-in module labels win on key collision."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.common_labels :
      can(regex("^[a-z][a-z0-9_-]{0,62}$", k)) &&
      (v == "" || can(regex("^[a-z0-9_-]{0,63}$", v)))
    ])
    error_message = <<-EOT
      Invalid common_labels.

      - Label keys must start with a lowercase letter and contain only lowercase letters, numbers, dashes (-), and underscores (_)
      - Label values must be empty or contain only lowercase letters, numbers, dashes (-), and underscores (_)
      - Maximum length for both keys and values is 63 characters
    EOT
  }
}

variable "n8n_fqdn" {
  description = "Fully-qualified domain name for n8n (e.g. n8n.example.com). Must match the certificate served for the chosen tls_mode."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9][a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$", var.n8n_fqdn))
    error_message = "Value must be a valid fully qualified domain name (e.g. n8n.example.com)."
  }

  validation {
    condition = alltrue([
      for label in split(".", var.n8n_fqdn) :
      length(label) >= 1 && length(label) <= 63 && can(regex("^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$", label))
    ])
    error_message = "Every dot-separated label of n8n_fqdn must be 1 to 63 characters, start and end with an alphanumeric character, and contain only alphanumerics and hyphens (the DNS-1123 label rule GKE Ingress/ManagedCertificate and n8n's own host handling enforce)."
  }
}

variable "n8n_webhook_url" {
  description = "Public HTTPS base URL used for webhook callbacks (e.g. https://webhooks.example.com), mapped to N8N_WEBHOOK_URL on every n8n role. The legacy WEBHOOK_URL is also set, with the same value, unless the image tags prove n8n 2.30.0 or newer (the first release that reads N8N_WEBHOOK_URL), since n8n logs a deprecation warning for it from that release on. Defaults to https://<n8n_fqdn> when not set. Override when webhooks are served from a different host than the n8n UI; the editor/OAuth base URL (N8N_EDITOR_BASE_URL) always stays https://<n8n_fqdn> regardless of this setting. Must be an https:// base URL with no embedded userinfo credentials, query string, or fragment."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_webhook_url == null ? true : can(regex("^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^?#[:space:]]*)?$", var.n8n_webhook_url))
    error_message = "n8n_webhook_url must be null or an https:// base URL (e.g. https://webhooks.example.com) with no embedded userinfo credentials (no user:pass@), query string (?), or fragment (#)."
  }
}

variable "n8n_license_key" {
  description = "n8n Enterprise license activation key. Get one at https://n8n.io/pricing. Leave null when n8n_license_key_secret_ref selects a caller-managed Kubernetes Secret holding the key instead, or when n8n_license_cert_secret_ref selects a caller-managed Secret holding an offline N8N_LICENSE_CERT certificate for air-gapped or egress-restricted clusters that cannot reach n8n's license server - exactly one of the three must be set."
  type        = string
  default     = null
  sensitive   = true
}

# The completeness/mutual-exclusivity condition below references this
# variable, n8n_license_key, and n8n_license_cert_secret_ref, so it lives on
# exactly one of the three (here) rather than being duplicated on all of
# them, per the acyclicity rationale documented on
# n8n_database_password_secret_ref (two variables validating each other
# cycles Terraform's validation graph).
variable "n8n_license_key_secret_ref" {
  description = "Reference to an existing Kubernetes Secret (in the n8n namespace) holding the n8n Enterprise license activation key, instead of passing the value directly through n8n_license_key. key defaults to \"license-key\" when omitted. The module never reads the referenced Secret's value; it only passes the reference through to the n8n Helm chart's license.existingSecret. Mutually exclusive with n8n_license_key and n8n_license_cert_secret_ref - exactly one of the three is required. Also required (instead of n8n_license_key) when existing_n8n_core_secret_name is set, per the chart's core-Secret contract (see existing_n8n_core_secret_name)."
  type = object({
    name = string
    key  = optional(string, "license-key")
  })
  default = null

  validation {
    condition = length([
      for v in [var.n8n_license_key, var.n8n_license_key_secret_ref, var.n8n_license_cert_secret_ref] : v if v != null
    ]) == 1
    error_message = "Set exactly one of n8n_license_key, n8n_license_key_secret_ref, or n8n_license_cert_secret_ref."
  }
}

# Offline license activation (N8N_LICENSE_CERT): for air-gapped or
# egress-restricted clusters that cannot reach n8n's license server. Rendered
# through the shared config.extraEnv list as a secretKeyRef (n8n.tf's
# local.n8n_license_cert_env), not through the chart's license.existingSecret
# block, which only ever maps to N8N_LICENSE_ACTIVATION_KEY - the chart has no
# cert-shaped equivalent of that block. license.enabled still renders true on
# this path (n8n.tf) because the chart also gates
# N8N_MULTI_MAIN_SETUP_ENABLED on license.enabled, not on which credential
# backs it; turning it off would silently break multi-main leader election.
variable "n8n_license_cert_secret_ref" {
  description = "Reference to an existing Kubernetes Secret (in the n8n namespace) holding a base64-encoded n8n Enterprise offline license certificate (N8N_LICENSE_CERT), for air-gapped or egress-restricted clusters that cannot reach n8n's license server to activate n8n_license_key. key defaults to \"cert\" when omitted. The module never reads the referenced Secret's value; it only renders the name and key into the shared config.extraEnv list as a secretKeyRef, never into the chart's license.existingSecret block. Mutually exclusive with n8n_license_key and n8n_license_key_secret_ref - exactly one of the three is required."
  type = object({
    name = string
    key  = optional(string, "cert")
  })
  default = null

  validation {
    condition     = var.n8n_license_cert_secret_ref == null ? true : (trimspace(var.n8n_license_cert_secret_ref.name) != "" && trimspace(var.n8n_license_cert_secret_ref.key) != "")
    error_message = "n8n_license_cert_secret_ref.name and .key must be non-empty when set."
  }
}

# ── Credential overwrites ──────────────────────────────────────────────────
# Lets a caller pre-populate node credential fields from an existing Secret
# they own (n8n's Credential overwrites feature), instead of the plaintext
# escape-hatch documented at https://docs.n8n.io/administer/manage-credentials/credential-overwrites/.
# The module never reads the referenced Secret's value; it only mounts the
# selected key read-only and points CREDENTIALS_OVERWRITE_DATA_FILE at it, on
# every n8n role (main, worker, webhook processor). See
# local.n8n_credentials_overwrite_enabled (locals.tf) and its wiring in
# n8n.tf.
variable "n8n_credentials_overwrite_secret_ref" {
  description = "Reference to an existing Kubernetes Secret (in the n8n namespace) holding a credential-overwrites JSON payload, mounted read-only at /etc/n8n/credentials-overwrite/overwrites.json on every n8n role with CREDENTIALS_OVERWRITE_DATA_FILE pointed at it. The module never reads, hashes, or copies the referenced Secret's contents into Terraform state, Helm values, or another Secret; a missing Secret or key fails at pod-start time, not at plan time. Changing only the Secret's contents does not trigger an automatic rollout: restart n8n-main, n8n-worker, and n8n-webhook-processor deployments to pick up new data. Leave null (the default) to leave credential overwrites unconfigured, in which case CREDENTIALS_OVERWRITE_DATA/CREDENTIALS_OVERWRITE_DATA_FILE remain available through n8n_extra_env as before."
  type = object({
    name = string
    key  = string
  })
  default = null

  validation {
    # Terraform does not short-circuit ||; a bare `var.x == null ||
    # <attribute access on var.x>` still evaluates the right-hand side and
    # errors on Terraform 1.9.x (the CI floor) when var.x is null. Use a
    # ternary so the attribute access only happens when var.x is non-null.
    condition     = var.n8n_credentials_overwrite_secret_ref == null ? true : (trimspace(var.n8n_credentials_overwrite_secret_ref.name) != "" && trimspace(var.n8n_credentials_overwrite_secret_ref.key) != "")
    error_message = "n8n_credentials_overwrite_secret_ref.name and .key must be non-empty."
  }

  validation {
    condition     = var.n8n_credentials_overwrite_secret_ref == null || !contains([for v in var.n8n_extra_volumes : v.name], "credentials-overwrite")
    error_message = "n8n_credentials_overwrite_secret_ref reserves the \"credentials-overwrite\" volume name for its own read-only mount while set; remove or rename the conflicting n8n_extra_volumes entry."
  }

  validation {
    condition = var.n8n_credentials_overwrite_secret_ref == null || !anytrue([
      for m in var.n8n_extra_volume_mounts : (
        m.mount_path == "/etc/n8n/credentials-overwrite" ||
        startswith(m.mount_path, "/etc/n8n/credentials-overwrite/") ||
        startswith("/etc/n8n/credentials-overwrite/", "${m.mount_path}/")
      )
    ])
    error_message = "n8n_credentials_overwrite_secret_ref reserves /etc/n8n/credentials-overwrite/overwrites.json for its own mount while set; move the conflicting n8n_extra_volume_mounts entry to a non-overlapping path."
  }

  validation {
    condition = var.n8n_credentials_overwrite_secret_ref == null || !anytrue([
      for e in var.n8n_extra_env : contains(["CREDENTIALS_OVERWRITE_DATA", "CREDENTIALS_OVERWRITE_DATA_FILE"], e.name)
    ])
    error_message = "n8n_credentials_overwrite_secret_ref reserves CREDENTIALS_OVERWRITE_DATA and CREDENTIALS_OVERWRITE_DATA_FILE while set (the module sets CREDENTIALS_OVERWRITE_DATA_FILE itself from this reference); remove the conflicting n8n_extra_env entry."
  }
}

variable "n8n_kube_namespace" {
  description = "Kubernetes namespace to deploy n8n into. Also names the existing namespace when create_namespace = false."
  type        = string
  default     = "n8n"
}

variable "create_namespace" {
  description = "When true (the default), the module creates the n8n_kube_namespace namespace. Set to false to deploy into an existing namespace the module does not read, create, change, or delete."
  type        = bool
  default     = true
  nullable    = false
}

# ── Existing core Secret (n8n_kube_namespace) ─────────────────────────────────

variable "n8n_encryption_key" {
  description = "Direct n8n encryption key to reuse instead of letting the module generate one, e.g. when restoring/cloning a database whose existing credentials were encrypted with a known key. Exactly 64 hexadecimal characters, matching the module's own generated-key format (32 random bytes, hex-encoded). Mutually exclusive with existing_n8n_core_secret_name, which supplies the encryption key through an entire caller-managed core Secret instead. Leave null (the default) for the module to generate one, whose value is exposed by the n8n_encryption_key output. This reuses a key; it does not rotate one or prove the key matches a given database."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.n8n_encryption_key == null || can(regex("^[0-9a-fA-F]{64}$", var.n8n_encryption_key))
    error_message = "n8n_encryption_key must be exactly 64 hexadecimal characters, matching the module's own generated-key format."
  }

  validation {
    condition     = var.n8n_encryption_key == null || var.existing_n8n_core_secret_name == null
    error_message = "n8n_encryption_key and existing_n8n_core_secret_name are mutually exclusive: a direct key has nowhere to go once the caller supplies the entire core Secret."
  }
}

variable "existing_n8n_core_secret_name" {
  description = "Name of an existing Kubernetes Secret (in n8n_kube_namespace) holding N8N_ENCRYPTION_KEY, N8N_HOST, N8N_PORT, and N8N_PROTOCOL - the n8n Helm chart's secretRefs.existingSecret core-Secret contract. When set, the module creates no core Secret and generates no encryption key; n8n_license_key_secret_ref or n8n_license_cert_secret_ref must then be set (not n8n_license_key), because the chart's core-Secret contract requires the license to come from a separate Secret. Leave null (the default) for the module to generate the encryption key and create the core Secret itself."
  type        = string
  default     = null

  validation {
    condition     = var.existing_n8n_core_secret_name == null ? true : (var.n8n_license_key_secret_ref != null || var.n8n_license_cert_secret_ref != null)
    error_message = "n8n_license_key_secret_ref or n8n_license_cert_secret_ref is required when existing_n8n_core_secret_name is set; the chart's core-Secret contract requires the license to come from a separate Secret reference, not n8n_license_key."
  }
}

# ── Ingress ownership ──────────────────────────────────────────────────────────

variable "create_ingress" {
  description = "When true (the default), the module creates and manages the global load-balancer address, Cloud DNS record, GKE ingress, BackendConfig, FrontendConfig, TLS resources, and load-balancer teardown delay. Set to false to let the caller own ingress, DNS, and TLS; use the module's route and service outputs to build a compatible ingress."
  type        = bool
  default     = true
  nullable    = false
}

# ── n8n chart ─────────────────────────────────────────────────────────────────

variable "n8n_chart_version" {
  description = "n8n Helm chart version to deploy (n8n-io/n8n-hosting charts/n8n). Must be an exact semantic version (e.g. \"1.10.1\"), not a range or floating tag, so every apply is deterministic."
  type        = string
  default     = "1.14.0"

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z-.]+)?(\\+[0-9A-Za-z-.]+)?$", var.n8n_chart_version))
    error_message = "n8n_chart_version must be an exact semantic version, e.g. \"1.10.1\" (optionally with a -prerelease or +build suffix). Version ranges (~>, >=) and floating tags (latest) are not accepted."
  }
}

variable "n8n_chart_repository" {
  description = "Helm chart repository the n8n chart is installed from. Accepts an HTTPS chart-repository URL or an OCI registry reference (oci://...), so a private mirror can replace the public upstream (oci://ghcr.io/n8n-io/n8n-helm-chart) for a cluster with no egress to it. The mirror must serve the exact version named by n8n_chart_version; this module does not verify that a mirrored repository actually carries it."
  type        = string
  default     = "oci://ghcr.io/n8n-io/n8n-helm-chart"
  nullable    = false

  validation {
    condition     = startswith(var.n8n_chart_repository, "https://") || startswith(var.n8n_chart_repository, "oci://")
    error_message = "n8n_chart_repository must start with https:// or oci://."
  }
}

variable "keda_chart_version" {
  description = "KEDA Helm chart version to deploy (kedacore/charts). Pinned so every apply installs the same operator version; bump deliberately and re-run the test suite rather than floating to latest. Must be an exact semantic version. Passed through to modules/controllers. Ignored when install_keda = false."
  type        = string
  default     = "2.20.1"

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z-.]+)?(\\+[0-9A-Za-z-.]+)?$", var.keda_chart_version))
    error_message = "keda_chart_version must be an exact semantic version, e.g. \"2.20.1\" (optionally with a -prerelease or +build suffix). Version ranges (~>, >=) and floating tags (latest) are not accepted."
  }
}

# ── Controllers submodule (modules/controllers) ───────────────────────────────
# The root module invokes modules/controllers by default to install KEDA and
# the optional pd-balanced StorageClass (controllers.tf). These inputs are the
# root's pass-through/ownership surface for that submodule; see
# modules/controllers/variables.tf for the submodule's own contract.

variable "install_keda" {
  description = "When true (the default), the module installs and manages the KEDA Helm release via modules/controllers before creating n8n worker ScaledObjects. Set to false to use an existing KEDA installation; existing_keda_prerequisites_attestation must then be true whenever n8n_worker_keda_enabled = true."
  type        = bool
  default     = true
  nullable    = false
}

# This attestation is only ever consumed by its own validation block below;
# tflint does not treat a variable's self-referential validation condition as
# a use.
# tflint-ignore: terraform_unused_declarations
variable "existing_keda_prerequisites_attestation" {
  description = "Explicit attestation that a compatible KEDA operator and CRDs are already installed and running on the cluster. The module cannot safely audit this; it trusts this attestation. Required (must be true) when install_keda = false and n8n_worker_keda_enabled = true. Ignored otherwise."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = var.install_keda || !var.n8n_worker_keda_enabled || var.existing_keda_prerequisites_attestation
    error_message = "existing_keda_prerequisites_attestation must be true when install_keda = false and n8n_worker_keda_enabled = true, confirming a compatible KEDA operator and CRDs already exist on the cluster."
  }
}

variable "keda_chart_repository" {
  description = "Helm chart repository KEDA is installed from (modules/controllers). Accepts an HTTPS chart-repository URL or an OCI registry reference (oci://...), so a private mirror can replace the public kedacore charts. Ignored when install_keda = false."
  type        = string
  default     = "https://kedacore.github.io/charts"
  nullable    = false

  validation {
    condition     = startswith(var.keda_chart_repository, "https://") || startswith(var.keda_chart_repository, "oci://")
    error_message = "keda_chart_repository must start with https:// or oci://."
  }
}

variable "create_pd_balanced_storage_class" {
  description = "When true (the default), the module creates an explicit pd-balanced StorageClass via modules/controllers for stateful workloads that run beside n8n (n8n itself is stateless). Set to false to omit it, e.g. when the caller already defines an equivalent StorageClass."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_image_tag" {
  description = "n8n application image tag to deploy (e.g. \"2.27.4\"). When it is null (the default), the Helm chart's own default applies: since chart 1.12.0 that is the chart's appVersion (2.41.4 for the default 1.14.0), a fixed n8n version that only moves when n8n_chart_version does; charts before 1.12.0 defaulted to the floating `stable` tag instead. This module requires n8n 2.0 or newer; n8n 1.x is not supported. The tag also decides whether the module still sends the legacy WEBHOOK_URL: only when it names a version below n8n 2.30.0, or when no version can be established (a floating or unversioned tag, or a null tag on a private chart mirror or a chart before 1.12.0). A null tag on the default chart repository at chart 1.12.0 or newer runs the chart's appVersion and gets no WEBHOOK_URL. Pin this to a concrete version to upgrade n8n independently of the chart, and to avoid crossing major-version boundaries (e.g. the n8n 2.0 breaking changes) on a chart bump. See https://docs.n8n.io/2-0-breaking-changes/ for the n8n 2.x migration guide."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_image_tag))
    error_message = "n8n_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"1.2.3\", \"1.2.3-alpine\"). Set to null to use the chart's default (its appVersion)."
  }
}

# ── Application images ─────────────────────────────────────────────────────────

variable "n8n_image_repository" {
  description = "Container image repository for the n8n application, without a tag (e.g. \"us-docker.pkg.dev/<project>/<repo>/n8n\"). When it is null (the default), the Helm chart's own repository applies (currently docker.n8n.io/n8nio/n8n). Point this at a custom image, for example one with community packages baked in so they are not reinstalled on every pod boot. The image must be pullable: a public registry needs nothing extra, GKE nodes can already pull from Artifact Registry and Container Registry in the same project without credentials, and any other private registry needs its credentials listed in n8n_image_pull_secrets. Set the tag through n8n_image_tag, not here, and set n8n_task_runner_image_tag alongside it whenever the tag is not itself a published n8n version."
  type        = string
  default     = null

  validation {
    condition = var.n8n_image_repository == null ? true : (
      length(var.n8n_image_repository) <= 255 &&
      can(regex("^(?:(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*|\\[[0-9A-Fa-f:]+\\])(?::[0-9]+)?/)?[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*)*$", var.n8n_image_repository))
    )
    error_message = "n8n_image_repository must be a bare image repository reference that Docker can pull: an optional registry host with an optional port, then one or more lowercase path components (e.g. \"us-docker.pkg.dev/my-project/n8n/n8n\", \"n8nio/n8n\"). No scheme (\"https://\"), no whitespace, no uppercase path components, and no empty label anywhere, which rules out a trailing slash, a doubled slash, and a doubled dot. Set to null to use the chart's default (docker.n8n.io/n8nio/n8n)."
  }

  validation {
    condition     = var.n8n_image_repository == null ? true : !can(regex(":", reverse(split("/", var.n8n_image_repository))[0]))
    error_message = "n8n_image_repository must not include a tag or digest, because the chart appends the tag itself. Pass the version via n8n_image_tag instead."
  }
}

variable "n8n_image_pull_policy" {
  description = "Image pull policy for the n8n application image. Maps to the chart's image.pullPolicy. Leave null (the default) to use the chart's own default (IfNotPresent). One of Always, IfNotPresent, or Never."
  type        = string
  default     = null

  validation {
    # Ternary, not ||: Terraform does not short-circuit, and contains() errors
    # on a null needle under the CI-pinned Terraform 1.9.x.
    condition     = var.n8n_image_pull_policy == null ? true : contains(["Always", "IfNotPresent", "Never"], var.n8n_image_pull_policy)
    error_message = "n8n_image_pull_policy must be one of Always, IfNotPresent, or Never, or null to use the chart's default (IfNotPresent)."
  }
}

variable "n8n_image_pull_secrets" {
  description = "Names of existing Kubernetes Secrets of type kubernetes.io/dockerconfigjson, in the n8n namespace, that the pods authenticate to their image registry with. Leave empty (the default) unless n8n_image_repository points somewhere the node pool's default credentials cannot already reach: a public registry and Artifact Registry/Container Registry in this project both pull without credentials. Setting this moves ownership of the n8n Kubernetes ServiceAccount from the Helm chart to the module (the pinned chart renders imagePullSecrets nowhere, on the pod spec or on the ServiceAccount, so attaching the secrets to the account the pods already run as is the only way in), and the module keeps the Workload Identity annotation on the account it creates instead. Create and rotate the Secrets yourself; the module takes names, not credentials, so none of them land in Terraform state."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for name in var.n8n_image_pull_secrets :
      can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", name))
    ])
    error_message = "Every n8n_image_pull_secrets entry must be a DNS-1123 subdomain, which is what Kubernetes requires of a Secret name: lowercase alphanumerics, hyphens and dots, starting and ending with an alphanumeric, with no empty label (e.g. \"ar-pull-creds\")."
  }

  validation {
    condition = alltrue([
      for name in var.n8n_image_pull_secrets : length(name) <= 253
    ])
    error_message = "Every n8n_image_pull_secrets entry must be 253 characters or fewer, the Kubernetes limit on a Secret name."
  }

  validation {
    condition = alltrue([
      for name in var.n8n_image_pull_secrets : alltrue([
        for label in split(".", name) :
        length(label) >= 1 && length(label) <= 63 && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", label))
      ])
    ])
    error_message = "Every dot-separated label of each n8n_image_pull_secrets entry must be 1 to 63 characters, start and end with a lowercase alphanumeric character, and contain only lowercase alphanumerics and hyphens (Kubernetes' actual DNS-1123 subdomain label rule, not just the 253-character total-length check above)."
  }

  validation {
    condition     = length(distinct(var.n8n_image_pull_secrets)) == length(var.n8n_image_pull_secrets)
    error_message = "n8n_image_pull_secrets must not repeat a Secret name. Listing one twice adds nothing, since the kubelet tries each entry once."
  }
}

variable "n8n_custom_extensions_path" {
  description = "Absolute path inside the n8n container that n8n scans for custom nodes at startup (e.g. \"/opt/n8n-nodes\"). Maps to N8N_CUSTOM_EXTENSIONS, and is set on every pod type (main, worker, webhook processor). This is the supported way to ship nodes baked into a custom image: since n8n 1.0 the loader no longer picks up nodes from the image's global node_modules, so a plain npm install into the image is never seen. Something has to put files at this path, so pair this with n8n_image_repository pointing at an image that bakes them in. The path must be outside /home/node/.n8n, which the chart mounts over on main pods. Nodes loaded this way are registered under the package name CUSTOM, so a node whose type was n8n-nodes-example.myNode when installed from npm becomes CUSTOM.myNode, and existing workflows referencing the npm-qualified type will not resolve. Leave null (the default) to omit the env var entirely."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : can(regex("^/[^[:space:];]*$", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be an absolute container path with no whitespace and no semicolon (e.g. \"/opt/n8n-nodes\"). n8n splits N8N_CUSTOM_EXTENSIONS on \";\", so a semicolon here would be parsed as two directories and silently drop all but the last."
  }

  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : !can(regex("//|/\\.\\.?(/|$)", var.n8n_custom_extensions_path))
    error_message = "n8n_custom_extensions_path must be a canonical path: no repeated slashes and no \".\" or \"..\" components (e.g. \"/opt/n8n-nodes\"). Those spellings resolve to the same directory inside the container but would slip past the /home/node/.n8n shadowing check."
  }

  validation {
    condition     = var.n8n_custom_extensions_path == null ? true : (var.n8n_custom_extensions_path == "/" || !endswith(var.n8n_custom_extensions_path, "/"))
    error_message = "n8n_custom_extensions_path must not end in a trailing slash (e.g. \"/opt/n8n-nodes\", not \"/opt/n8n-nodes/\"). Same reason as the canonical-path rule above: the two spellings are the same directory to the container but different strings to any coverage check that compares this path literally."
  }

  validation {
    condition = var.n8n_custom_extensions_path == null ? true : !(
      var.n8n_custom_extensions_path == "/home/node/.n8n" ||
      startswith(var.n8n_custom_extensions_path, "/home/node/.n8n/")
    )
    error_message = "n8n_custom_extensions_path must not be inside /home/node/.n8n. The chart mounts an emptyDir there on main pods, which hides whatever the image baked in, so the nodes would load on workers and webhook processors but not on mains. Use a path outside it, for example /opt/n8n-nodes."
  }
}

# ── Caller-managed volumes ────────────────────────────────────────────────────
# Lets a caller mount an existing ConfigMap, Secret, or PVC into every n8n role
# (main, worker, webhook processor) through the chart's extraVolumes /
# extraVolumeMounts, without the module creating or reading the referenced
# object. Merged with the module's own Redis CA mount (local.manage_redis_tls_ca)
# in local.n8n_caller_extra_volumes / local.n8n_caller_extra_volume_mounts
# (locals.tf) and wired into helm_release.n8n (n8n.tf).

variable "n8n_extra_volumes" {
  description = "Existing ConfigMaps, Secrets, or PVCs to mount into every n8n pod (main, worker, webhook processor) via the chart's extraVolumes. Each entry has a name and exactly one typed source: config_map, secret, or persistent_volume_claim. The module creates and reads none of the referenced objects; provisioning and lifecycle stay the caller's responsibility. A PVC mounted read-write on more than one pod needs a caller-provisioned ReadWriteMany-capable StorageClass, since n8n runs multiple replicas of every role. Pair entries here with n8n_extra_volume_mounts to actually mount them somewhere; declaring a volume with no matching mount has no effect. Reserved volume names data, task-runner-config, and redis-ca belong to the chart/module and cannot be reused."
  type = list(object({
    name = string
    config_map = optional(object({
      name = string
      items = optional(list(object({
        key  = string
        path = string
      })), null)
      default_mode = optional(string, null)
    }), null)
    secret = optional(object({
      name = string
      items = optional(list(object({
        key  = string
        path = string
      })), null)
      default_mode = optional(string, null)
    }), null)
    persistent_volume_claim = optional(object({
      claim_name = string
    }), null)
  }))
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for v in var.n8n_extra_volumes :
      length(compact([v.config_map != null ? "x" : "", v.secret != null ? "x" : "", v.persistent_volume_claim != null ? "x" : ""])) == 1
    ])
    error_message = "Each n8n_extra_volumes entry must set exactly one of config_map, secret, or persistent_volume_claim."
  }

  validation {
    condition = alltrue([
      for v in var.n8n_extra_volumes : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", v.name))
    ])
    error_message = "Each n8n_extra_volumes entry's name must be a valid Kubernetes volume name: lowercase alphanumerics and hyphens, starting and ending with an alphanumeric, 63 characters or fewer."
  }

  validation {
    condition     = length(distinct([for v in var.n8n_extra_volumes : v.name])) == length(var.n8n_extra_volumes)
    error_message = "n8n_extra_volumes must not repeat a volume name."
  }

  validation {
    condition = alltrue([
      for v in var.n8n_extra_volumes : !contains(["data", "task-runner-config", "redis-ca"], v.name)
    ])
    error_message = "n8n_extra_volumes must not use a reserved volume name (data, task-runner-config, redis-ca), which the module/chart already owns."
  }

  validation {
    # Nested ternaries, not `v.config_map == null || v.config_map.default_mode
    # == null || ...`: Terraform does not short-circuit ||, so the attribute
    # access still runs and errors on Terraform 1.9.x (the CI floor) whenever
    # an entry has no config_map at all.
    condition = alltrue([
      for v in var.n8n_extra_volumes :
      v.config_map == null ? true : (v.config_map.default_mode == null ? true : can(regex("^[0-7]{1,4}$", v.config_map.default_mode)))
    ])
    error_message = "n8n_extra_volumes[].config_map.default_mode must be an octal permission string using only digits 0-7 (e.g. \"0440\"), or null to use the chart/Kubernetes default."
  }

  validation {
    condition = alltrue([
      for v in var.n8n_extra_volumes :
      v.secret == null ? true : (v.secret.default_mode == null ? true : can(regex("^[0-7]{1,4}$", v.secret.default_mode)))
    ])
    error_message = "n8n_extra_volumes[].secret.default_mode must be an octal permission string using only digits 0-7 (e.g. \"0440\"), or null to use the chart/Kubernetes default."
  }

  validation {
    condition = alltrue(flatten([
      for v in var.n8n_extra_volumes : v.config_map == null ? [] : (v.config_map.items == null ? [] : [
        for i in v.config_map.items : i.path != "" && !startswith(i.path, "/") && !can(regex("(^|/)\\.\\.?(/|$)", i.path))
      ])
    ]))
    error_message = "n8n_extra_volumes[].config_map.items[].path must be a non-empty relative path with no leading slash and no \".\" or \"..\" components."
  }

  validation {
    condition = alltrue(flatten([
      for v in var.n8n_extra_volumes : v.secret == null ? [] : (v.secret.items == null ? [] : [
        for i in v.secret.items : i.path != "" && !startswith(i.path, "/") && !can(regex("(^|/)\\.\\.?(/|$)", i.path))
      ])
    ]))
    error_message = "n8n_extra_volumes[].secret.items[].path must be a non-empty relative path with no leading slash and no \".\" or \"..\" components."
  }
}

variable "n8n_extra_volume_mounts" {
  description = "Mounts of n8n_extra_volumes entries into every n8n pod (main, worker, webhook processor) via the chart's extraVolumeMounts. Each entry's name must match a declared n8n_extra_volumes entry. mount_path must be an absolute, canonical container path outside the module's own protected mounts (/home/node/.n8n, the main pod's data directory; /etc/n8n-certs, the managed Redis CA mount). read_only defaults to true; set false only for a PVC the caller's workload actually needs to write to."
  type = list(object({
    name       = string
    mount_path = string
    sub_path   = optional(string, null)
    read_only  = optional(bool, true)
  }))
  default  = []
  nullable = false

  validation {
    condition = alltrue([
      for m in var.n8n_extra_volume_mounts : contains([for v in var.n8n_extra_volumes : v.name], m.name)
    ])
    error_message = "Each n8n_extra_volume_mounts entry's name must match a volume declared in n8n_extra_volumes."
  }

  validation {
    condition     = length(distinct([for m in var.n8n_extra_volume_mounts : m.name])) == length(var.n8n_extra_volume_mounts)
    error_message = "n8n_extra_volume_mounts must not mount the same volume name more than once."
  }

  validation {
    condition     = length(distinct([for m in var.n8n_extra_volume_mounts : m.mount_path])) == length(var.n8n_extra_volume_mounts)
    error_message = "n8n_extra_volume_mounts must not repeat a mount_path; Kubernetes rejects two volumes mounted at the same container path."
  }

  validation {
    condition = alltrue([
      for m in var.n8n_extra_volume_mounts : can(regex("^/[^[:space:];]*$", m.mount_path))
    ])
    error_message = "n8n_extra_volume_mounts[].mount_path must be an absolute container path with no whitespace or semicolon (e.g. \"/opt/n8n-nodes\")."
  }

  validation {
    condition = alltrue([
      for m in var.n8n_extra_volume_mounts : !can(regex("//|/\\.\\.?(/|$)", m.mount_path))
    ])
    error_message = "n8n_extra_volume_mounts[].mount_path must be a canonical path: no repeated slashes and no \".\" or \"..\" components."
  }

  validation {
    condition = alltrue([
      for m in var.n8n_extra_volume_mounts : m.mount_path == "/" || !endswith(m.mount_path, "/")
    ])
    error_message = "n8n_extra_volume_mounts[].mount_path must not end in a trailing slash."
  }

  validation {
    condition = alltrue([
      for m in var.n8n_extra_volume_mounts : !(
        m.mount_path == "/home/node/.n8n" || startswith(m.mount_path, "/home/node/.n8n/") ||
        m.mount_path == "/etc/n8n-certs" || startswith(m.mount_path, "/etc/n8n-certs/")
      )
    ])
    error_message = "n8n_extra_volume_mounts[].mount_path must not overlap the module's own protected mounts: /home/node/.n8n (main pod's data directory) or /etc/n8n-certs (managed Redis CA mount)."
  }
}

variable "n8n_helm_timeout" {
  description = "Seconds Terraform waits for the n8n Helm release to converge. Increase for large deployments where rolling out 50+ pods (workers + webhook processors + main) exceeds the default. 600s is fine for the default/medium examples; large deployments at 250+ pods need ~1800s."
  type        = number
  default     = 600

  validation {
    condition     = var.n8n_helm_timeout >= 60
    error_message = "n8n_helm_timeout must be at least 60 seconds."
  }
}

variable "n8n_timezone" {
  description = "Timezone for n8n (e.g. UTC, America/New_York, Europe/London)"
  type        = string
  default     = "UTC"
}

variable "n8n_log_level" {
  description = "n8n log level. Maps to the N8N_LOG_LEVEL environment variable. One of: silent, error, warn, info, debug, verbose."
  type        = string
  default     = "info"

  validation {
    condition     = contains(["silent", "error", "warn", "info", "debug", "verbose"], var.n8n_log_level)
    error_message = "n8n_log_level must be one of: silent, error, warn, info, debug, verbose."
  }
}

variable "n8n_log_output" {
  description = "n8n log output destination(s). Maps to the N8N_LOG_OUTPUT environment variable. Comma-separated subset of: console, file (e.g. \"console\", \"file\", \"console,file\"). Note: this variable does NOT control log *format*, setting an invalid value (e.g. \"json\") leaves Winston with no transport and silently drops all logs. To emit JSON-formatted logs, configure n8n's logging block separately; this env var only selects destinations."
  type        = string
  default     = "console"

  validation {
    condition     = alltrue([for v in split(",", var.n8n_log_output) : contains(["console", "file"], trimspace(v))])
    error_message = "n8n_log_output only accepts console and/or file (comma-separated, e.g. \"console\" or \"console,file\")."
  }
}

# ── n8n resource requests and limits ──────────────────────────────────────────

# Both CPU and memory validation regexes below match exactly the quantity
# grammar capacity.tf's parser supports (documented there): CPU as a bare,
# optionally fractional core count or a fractional millicore count suffixed
# with "m"; memory as a bare, optionally fractional byte count or a
# fractional quantity suffixed with Ki, Mi, or Gi. Anything else (e.g. "1C",
# "2vCPU", "1e9", a Kubernetes-valid but unsupported suffix like "Ti" or
# "2m" without units) would otherwise reach capacity.tf's tonumber()/endswith()
# parsing and fail as an expression error instead of a validation error.

variable "n8n_main_cpu_request" {
  description = "CPU request for n8n main pods (e.g. 1000m, 500m)"
  type        = string
  default     = "1000m"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_main_cpu_request))
    error_message = "n8n_main_cpu_request must be a bare core count (e.g. \"1\", \"0.5\") or a millicore count suffixed with m (e.g. \"1000m\", \"500m\"), the only CPU quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_main_cpu_limit" {
  description = "CPU limit for n8n main pods (e.g. 2000m, 1000m)"
  type        = string
  default     = "2000m"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_main_cpu_limit))
    error_message = "n8n_main_cpu_limit must be a bare core count (e.g. \"2\", \"1.5\") or a millicore count suffixed with m (e.g. \"2000m\"), the only CPU quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_main_memory_request" {
  description = "Memory request for n8n main pods (e.g. 2Gi, 1Gi)"
  type        = string
  default     = "2Gi"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi)?$", var.n8n_main_memory_request))
    error_message = "n8n_main_memory_request must be a bare byte count or a quantity suffixed with Ki, Mi, or Gi (e.g. \"2Gi\", \"512Mi\"), the only memory quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_main_memory_limit" {
  description = "Memory limit for n8n main pods (e.g. 4Gi, 2Gi)"
  type        = string
  default     = "4Gi"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi)?$", var.n8n_main_memory_limit))
    error_message = "n8n_main_memory_limit must be a bare byte count or a quantity suffixed with Ki, Mi, or Gi (e.g. \"4Gi\"), the only memory quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_worker_cpu_request" {
  description = "CPU request for n8n worker pods (e.g. 500m, 1000m)"
  type        = string
  default     = "500m"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_worker_cpu_request))
    error_message = "n8n_worker_cpu_request must be a bare core count (e.g. \"1\") or a millicore count suffixed with m (e.g. \"500m\"), the only CPU quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_worker_cpu_limit" {
  description = "CPU limit for n8n worker pods (e.g. 1000m, 2000m)"
  type        = string
  default     = "1000m"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_worker_cpu_limit))
    error_message = "n8n_worker_cpu_limit must be a bare core count or a millicore count suffixed with m (e.g. \"1000m\"), the only CPU quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_worker_memory_request" {
  description = "Memory request for n8n worker pods (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi)?$", var.n8n_worker_memory_request))
    error_message = "n8n_worker_memory_request must be a bare byte count or a quantity suffixed with Ki, Mi, or Gi (e.g. \"1Gi\"), the only memory quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_worker_memory_limit" {
  description = "Memory limit for n8n worker pods (e.g. 2Gi, 4Gi)"
  type        = string
  default     = "2Gi"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi)?$", var.n8n_worker_memory_limit))
    error_message = "n8n_worker_memory_limit must be a bare byte count or a quantity suffixed with Ki, Mi, or Gi (e.g. \"2Gi\"), the only memory quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_webhook_cpu_request" {
  description = "CPU request for n8n webhook processor pods (e.g. 300m, 500m)"
  type        = string
  default     = "300m"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_webhook_cpu_request))
    error_message = "n8n_webhook_cpu_request must be a bare core count or a millicore count suffixed with m (e.g. \"300m\"), the only CPU quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_webhook_cpu_limit" {
  description = "CPU limit for n8n webhook processor pods (e.g. 800m, 1000m)"
  type        = string
  default     = "800m"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_webhook_cpu_limit))
    error_message = "n8n_webhook_cpu_limit must be a bare core count or a millicore count suffixed with m (e.g. \"800m\"), the only CPU quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_webhook_memory_request" {
  description = "Memory request for n8n webhook processor pods (e.g. 512Mi, 1Gi)"
  type        = string
  default     = "512Mi"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi)?$", var.n8n_webhook_memory_request))
    error_message = "n8n_webhook_memory_request must be a bare byte count or a quantity suffixed with Ki, Mi, or Gi (e.g. \"512Mi\"), the only memory quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_webhook_memory_limit" {
  description = "Memory limit for n8n webhook processor pods (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi)?$", var.n8n_webhook_memory_limit))
    error_message = "n8n_webhook_memory_limit must be a bare byte count or a quantity suffixed with Ki, Mi, or Gi (e.g. \"1Gi\"), the only memory quantity grammar capacity.tf's parser supports."
  }
}

# ── Execution settings ────────────────────────────────────────────────────────

variable "n8n_worker_concurrency" {
  description = "Number of jobs each worker pod can process simultaneously, passed to the chart as the worker --concurrency flag. Verified against n8n 2.38.7: the worker ignores this flag whenever N8N_CONCURRENCY_PRODUCTION_LIMIT is set to anything other than -1, and the module always sets that variable from n8n_execution_concurrency_limit (default 100) on every role. With the defaults the effective worker concurrency is therefore 100, not 10, and KEDA-scaled additional workers only receive jobs once the first worker holds 100. To make this input effective, set n8n_execution_concurrency_limit = -1 or align both values deliberately."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.n8n_worker_concurrency >= 1 && floor(var.n8n_worker_concurrency) == var.n8n_worker_concurrency
    error_message = "n8n_worker_concurrency must be a whole number of at least 1."
  }
}

variable "n8n_execution_timeout" {
  description = "Default execution timeout in seconds (-1 to disable)"
  type        = number
  default     = 7200
}

variable "n8n_execution_timeout_max" {
  description = "Maximum execution timeout users can configure in seconds"
  type        = number
  default     = 7200
}

variable "n8n_execution_concurrency_limit" {
  description = "Maximum concurrent production executions (-1 to disable). Emitted as N8N_CONCURRENCY_PRODUCTION_LIMIT on main, worker, and webhook-processor pods. On n8n 2.38.7 a value other than -1 also replaces the worker --concurrency flag (n8n_worker_concurrency), so this value is the effective per-worker concurrency. See n8n_worker_concurrency."
  type        = number
  default     = 100
}

variable "n8n_pruning_max_age" {
  description = "Maximum age of execution records to retain, in hours (336 = 14 days)"
  type        = number
  default     = 336
}

variable "n8n_pruning_max_count" {
  description = "Maximum number of execution records to retain (0 = no limit)"
  type        = number
  default     = 10000
}

# ── Execution-save policy ─────────────────────────────────────────────────────
# Wired through local.n8n_executions_data (locals.tf) into the chart's
# executions.data map (n8n.tf), replacing what used to be four literals
# hardcoded there. Reserved against n8n_extra_env in
# local.n8n_managed_env_names (locals.tf) since the chart emits these as the
# EXECUTIONS_DATA_SAVE_* env vars.

variable "n8n_executions_data_save_on_success" {
  description = "Whether to save data for successful execution runs (the chart's executions.data.saveOnSuccess / EXECUTIONS_DATA_SAVE_ON_SUCCESS). \"all\" (the default, and n8n's own default) saves every successful execution; \"none\" saves none."
  type        = string
  default     = "all"
  nullable    = false

  validation {
    condition     = contains(["all", "none"], var.n8n_executions_data_save_on_success)
    error_message = "n8n_executions_data_save_on_success must be either \"all\" or \"none\"."
  }
}

variable "n8n_executions_data_save_on_error" {
  description = "Whether to save data for failed execution runs (the chart's executions.data.saveOnError / EXECUTIONS_DATA_SAVE_ON_ERROR). \"all\" (the default, and n8n's own default) saves every failed execution; \"none\" saves none."
  type        = string
  default     = "all"
  nullable    = false

  validation {
    condition     = contains(["all", "none"], var.n8n_executions_data_save_on_error)
    error_message = "n8n_executions_data_save_on_error must be either \"all\" or \"none\"."
  }
}

variable "n8n_executions_data_save_on_progress" {
  description = "Whether to save in-progress execution data as each node completes, so a still-running or crashed execution's partial state is visible (the chart's executions.data.saveOnProgress / EXECUTIONS_DATA_SAVE_ON_PROGRESS). Defaults to false, matching n8n's own default; enabling it increases database writes per execution."
  type        = bool
  default     = false
  nullable    = false
}

variable "n8n_executions_data_save_manual_executions" {
  description = "Whether to save data for executions triggered manually from the editor (the chart's executions.data.saveManualExecutions / EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS). Defaults to true, matching n8n's own default."
  type        = bool
  default     = true
  nullable    = false
}

# ── Graceful shutdown ─────────────────────────────────────────────────────────

variable "n8n_termination_grace_period" {
  description = "Seconds Kubernetes allows a terminating pod before force-killing it; the countdown starts when termination begins, before the preStop hook runs, not at SIGTERM. MINIMUM, do not lower below 60. Workers need time to finish in-flight executions before being terminated. The preStop sleep (n8n_prestop_sleep) runs inside this window, followed by n8n's own shutdown timeout (n8n_graceful_shutdown_timeout, or the chart's 30s default), so their sum must stay strictly below this value: an explicit n8n_graceful_shutdown_timeout that does not fit fails validation, and the chart default that does not fit raises the graceful_shutdown_fits_grace_period warning."
  type        = number
  default     = 60

  validation {
    condition     = var.n8n_termination_grace_period >= 60
    error_message = "Termination grace period must be at least 60 seconds to allow in-flight executions to complete."
  }
}

variable "n8n_prestop_sleep" {
  description = "Seconds the preStop hook sleeps before SIGTERM is sent, giving the load balancer time to drain the pod. MINIMUM, do not lower below 10. Counts against n8n_termination_grace_period together with n8n_graceful_shutdown_timeout (or the chart's 30s default); see that input for the combined limit."
  type        = number
  default     = 10

  validation {
    condition     = var.n8n_prestop_sleep >= 10
    error_message = "Pre-stop sleep must be at least 10 seconds for load balancer drain."
  }
}

# ── Task runners ──────────────────────────────────────────────────────────────

variable "n8n_task_runners_enabled" {
  description = "Enable task runner sidecars for isolated JavaScript and Python code execution"
  type        = bool
  default     = true
}

variable "n8n_task_runner_cpu_request" {
  description = "CPU request for task runner sidecar containers (e.g. 200m, 500m)"
  type        = string
  default     = "200m"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_task_runner_cpu_request))
    error_message = "n8n_task_runner_cpu_request must be a bare core count or a millicore count suffixed with m (e.g. \"200m\"), the only CPU quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_task_runner_cpu_limit" {
  description = "CPU limit for task runner sidecar containers (e.g. 1, 2000m)"
  type        = string
  default     = "1"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?m?$", var.n8n_task_runner_cpu_limit))
    error_message = "n8n_task_runner_cpu_limit must be a bare core count (e.g. \"1\") or a millicore count suffixed with m (e.g. \"2000m\"), the only CPU quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_task_runner_memory_request" {
  description = "Memory request for task runner sidecar containers (e.g. 512Mi, 1Gi)"
  type        = string
  default     = "512Mi"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi)?$", var.n8n_task_runner_memory_request))
    error_message = "n8n_task_runner_memory_request must be a bare byte count or a quantity suffixed with Ki, Mi, or Gi (e.g. \"512Mi\"), the only memory quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_task_runner_memory_limit" {
  description = "Memory limit for task runner sidecar containers (e.g. 1Gi, 2Gi)"
  type        = string
  default     = "1Gi"
  nullable    = false

  validation {
    condition     = can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi)?$", var.n8n_task_runner_memory_limit))
    error_message = "n8n_task_runner_memory_limit must be a bare byte count or a quantity suffixed with Ki, Mi, or Gi (e.g. \"1Gi\"), the only memory quantity grammar capacity.tf's parser supports."
  }
}

variable "n8n_task_runner_auto_shutdown_timeout" {
  description = "Seconds of inactivity before the runner process shuts down. Set to 0 to disable."
  type        = number
  default     = 15
}

variable "n8n_task_runner_python_enabled" {
  description = "Enable the native Python runner (beta). Required for Python code execution in workflows."
  type        = bool
  default     = true
}

variable "n8n_task_runner_image_repository" {
  description = "Container image repository for the task runner sidecar (chart default: n8nio/runners), without a tag. Leave null (the default) to use the chart's own repository. Set this alongside n8n_task_runner_image_tag when the n8n application image is mirrored into a private registry the runner image must also come from. Ignored when n8n_task_runners_enabled = false."
  type        = string
  default     = null

  validation {
    condition = var.n8n_task_runner_image_repository == null ? true : (
      length(var.n8n_task_runner_image_repository) <= 255 &&
      can(regex("^(?:(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)*|\\[[0-9A-Fa-f:]+\\])(?::[0-9]+)?/)?[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:__|[._]|-+)[a-z0-9]+)*)*$", var.n8n_task_runner_image_repository))
    )
    error_message = "n8n_task_runner_image_repository must be a bare image repository reference that Docker can pull, e.g. \"us-docker.pkg.dev/my-project/n8n/runners\" or \"n8nio/runners\". No scheme, no whitespace, no uppercase path components, and no tag or digest (set the tag via n8n_task_runner_image_tag). Set to null to use the chart's default (n8nio/runners)."
  }

  validation {
    condition     = var.n8n_task_runner_image_repository == null ? true : !can(regex(":", reverse(split("/", var.n8n_task_runner_image_repository))[0]))
    error_message = "n8n_task_runner_image_repository must not include a tag or digest, because the chart appends the tag itself. Pass the version via n8n_task_runner_image_tag instead."
  }
}

variable "n8n_task_runner_image_tag" {
  description = "Image tag for the task runner sidecar (n8nio/runners, or n8n_task_runner_image_repository when set). When it is null (the default), the chart falls back to the n8n application image's tag, which is correct as long as that tag is a published n8n version. Set this to the underlying n8n version when running a custom application image whose tag is not one (e.g. n8n_image_tag = \"2.27.4-mypackages\" together with n8n_task_runner_image_tag = \"2.27.4\"); otherwise the sidecar tries to pull an image tag that does not exist and every worker pod stays in ImagePullBackOff. For such a custom image, this tag's version also tells the module whether the app predates n8n 2.30.0 and still needs the legacy WEBHOOK_URL. Ignored when n8n_task_runners_enabled = false."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_task_runner_image_tag == null ? true : can(regex("^[a-zA-Z0-9_][a-zA-Z0-9._-]{0,127}$", var.n8n_task_runner_image_tag))
    error_message = "n8n_task_runner_image_tag must be a non-empty string with no whitespace, containing only alphanumeric characters, dots, underscores, and hyphens (e.g. \"2.27.4\"). Set to null to inherit the n8n application image's tag."
  }
}

variable "n8n_task_runner_request_timeout" {
  description = "Seconds n8n waits for a task runner to accept a Code node task. Wired to the N8N_RUNNERS_TASK_REQUEST_TIMEOUT env var on the main pod. Increase if Code nodes fail with 'task request timed out' under high concurrency (many parallel Code nodes competing for the single runner sidecar)."
  type        = number
  default     = 300
}

variable "n8n_task_runner_timeout" {
  description = "Seconds a task runner is allowed to spend executing an already-accepted Code node task before n8n cancels it. Wired to the N8N_RUNNERS_TASK_TIMEOUT env var on the worker pods (the only role carrying a runner sidecar in queue mode since chart 1.12.0). Distinct from n8n_task_runner_request_timeout, which bounds how long n8n waits for a runner to accept a task in the first place, not how long the task itself may run; the two are deliberately independent so a busy runner (acceptance) and a long-running script (execution) can be tuned separately."
  type        = number
  default     = 300
  nullable    = false

  validation {
    condition     = var.n8n_task_runner_timeout > 0 && var.n8n_task_runner_timeout == floor(var.n8n_task_runner_timeout)
    error_message = "n8n_task_runner_timeout must be a positive whole number of seconds."
  }
}

variable "n8n_task_runner_custom_config" {
  description = "Reference to an existing ConfigMap (in the n8n namespace) holding a custom task-runner launcher configuration file (n8n-task-runners.json by default), mounted read-only at /etc/n8n-task-runners.json on the task-runner sidecar of every worker pod via the chart's taskRunners.customConfig (since chart 1.12.0 main pods carry no sidecar in queue mode; n8n offloads manual executions to workers). Use this to allowlist additional JavaScript/Python packages for the Code node; the module never reads the referenced ConfigMap's contents, so the whole file's contents (not a merge or patch) come from the caller and must match the exact task-runner image/version in use (n8n_task_runner_image_tag, or the inherited n8n application image tag). Changing only the ConfigMap's contents does not trigger an automatic rollout: restart the n8n-main and n8n-worker deployments to pick up new data. Leave null (the default) to leave the launcher at the chart's built-in configuration. Requires n8n_task_runners_enabled = true."
  type = object({
    config_map_name = string
    config_map_key  = optional(string, "n8n-task-runners.json")
  })
  default = null

  validation {
    condition     = var.n8n_task_runner_custom_config == null || var.n8n_task_runners_enabled
    error_message = "n8n_task_runner_custom_config requires n8n_task_runners_enabled = true; without a runner sidecar there is nothing to mount the launcher configuration into."
  }

  validation {
    condition = var.n8n_task_runner_custom_config == null ? true : (
      can(regex("^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", var.n8n_task_runner_custom_config.config_map_name)) &&
      length(var.n8n_task_runner_custom_config.config_map_name) <= 253
    )
    error_message = "n8n_task_runner_custom_config.config_map_name must be a DNS-1123 subdomain, which is what Kubernetes requires of a ConfigMap name: lowercase alphanumerics, hyphens and dots, starting and ending with an alphanumeric, 253 characters or fewer."
  }

  validation {
    condition = var.n8n_task_runner_custom_config == null ? true : (
      can(regex("^[-._a-zA-Z0-9]+$", var.n8n_task_runner_custom_config.config_map_key)) &&
      length(var.n8n_task_runner_custom_config.config_map_key) <= 253
    )
    error_message = "n8n_task_runner_custom_config.config_map_key must be a valid Kubernetes ConfigMap data key: alphanumeric characters, '-', '_', or '.', 253 characters or fewer."
  }
}

# ── V8 heap ceiling ───────────────────────────────────────────────────────────

variable "n8n_node_max_old_space_size_mb" {
  description = "Whole MiB ceiling for Node.js's V8 old-space heap, applied identically to every n8n container (main, worker, webhook processor) via a global NODE_OPTIONS=--max-old-space-size=<value> on config.extraEnv. Does not change the task-runner sidecar's own heap, which is a separate Node.js process outside config.extraEnv. Null (the default) omits the setting so Node's own heuristic (roughly a quarter of the container's available memory) applies. Setting this reserves NODE_OPTIONS against n8n_extra_env while set; leave null to keep using n8n_extra_env's existing NODE_OPTIONS escape hatch. Leave headroom below the smallest n8n container's memory limit for non-heap V8/Node overhead (code cache, native buffers, thread stacks): setting this at or above that limit risks an OOM kill instead of a controlled heap error."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_node_max_old_space_size_mb == null ? true : (var.n8n_node_max_old_space_size_mb >= 256 && floor(var.n8n_node_max_old_space_size_mb) == var.n8n_node_max_old_space_size_mb)
    error_message = "n8n_node_max_old_space_size_mb must be a whole number of MiB of at least 256, or null to omit the override."
  }

  validation {
    condition     = var.n8n_node_max_old_space_size_mb == null ? true : !anytrue([for e in var.n8n_extra_env : e.name == "NODE_OPTIONS"])
    error_message = "n8n_node_max_old_space_size_mb reserves NODE_OPTIONS while set (the module sets it itself from this value); remove the conflicting n8n_extra_env entry, or leave this null to keep setting NODE_OPTIONS through n8n_extra_env."
  }
}

# ── Community registry and security-related runtime controls ────────────────

variable "n8n_community_packages_registry" {
  description = "HTTPS URL of a custom registry n8n uses to resolve community (npm) package installs, mapped to N8N_COMMUNITY_PACKAGES_REGISTRY on every n8n role (main, worker, webhook processor). Null (the default) leaves n8n's own npm registry default in place. Must not embed credentials (no user:pass@ userinfo); authenticate the registry itself (e.g. a network-level allowlist or a registry that accepts anonymous reads from the cluster's egress path), since this module has no separate mechanism for registry credentials. Community package installation itself is a distinct Enterprise entitlement from this registry override; setting this value does not enable or unlock community packages by itself."
  type        = string
  default     = null

  validation {
    condition     = var.n8n_community_packages_registry == null ? true : can(regex("^https://[^/@\\s]+(/\\S*)?$", var.n8n_community_packages_registry))
    error_message = "n8n_community_packages_registry must be a non-blank https:// URL with no embedded userinfo credentials (no user:pass@ before the host), or null to leave n8n's own registry default in place."
  }
}

variable "n8n_unverified_packages_enabled" {
  description = "Whether n8n allows installing community packages that have not passed n8n's verification process, mapped to N8N_UNVERIFIED_PACKAGES_ENABLED on every n8n role. Null (the default) leaves n8n's own upstream default in place, so a future n8n release can change that default without this module pinning it. Set explicitly (true or false) to fix the behavior regardless of the upstream default."
  type        = bool
  default     = null
}

variable "n8n_compression_max_decompressed_size_bytes" {
  description = "Maximum total decompressed size, in bytes, n8n allows when decompressing an archive (e.g. inside the Compression node), mapped to N8N_COMPRESSION_NODE_MAX_DECOMPRESSED_SIZE_BYTES on every n8n role. Null (the default) leaves n8n's own upstream limit in place, so a future n8n release can change that default without this module pinning it."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_compression_max_decompressed_size_bytes == null ? true : (var.n8n_compression_max_decompressed_size_bytes > 0 && floor(var.n8n_compression_max_decompressed_size_bytes) == var.n8n_compression_max_decompressed_size_bytes)
    error_message = "n8n_compression_max_decompressed_size_bytes must be a positive whole number of bytes, or null to leave n8n's own default in place."
  }
}

variable "n8n_compression_max_zip_entries" {
  description = "Maximum number of entries n8n allows when decompressing a zip archive (e.g. inside the Compression node), mapped to N8N_COMPRESSION_NODE_MAX_ZIP_ENTRIES on every n8n role. Null (the default) leaves n8n's own upstream limit in place, so a future n8n release can change that default without this module pinning it."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_compression_max_zip_entries == null ? true : (var.n8n_compression_max_zip_entries > 0 && floor(var.n8n_compression_max_zip_entries) == var.n8n_compression_max_zip_entries)
    error_message = "n8n_compression_max_zip_entries must be a positive whole number, or null to leave n8n's own default in place."
  }
}

# ── Pod DNS ───────────────────────────────────────────────────────────────────

variable "n8n_dns_config" {
  description = <<-EOT
    Pod-level DNS settings applied to the main, worker, and webhook-processor
    pods (the chart's top-level `dnsConfig`, rendered into all three pod
    specs). Defaults to null, which omits the block entirely and leaves
    Kubernetes' cluster DNS policy and resolver defaults unchanged, so this is
    a no-op unless set.

    Nameservers are validated as plain IPv4 or IPv6 addresses, at most 3,
    matching the limits the Kubernetes pod spec enforces at admission.

    Search domains are validated against strict RFC 1123 subdomain rules:
    lowercase alphanumeric labels and hyphens only, no underscores, and no
    bare "." or trailing dot. This module targets GKE's supported release
    channels (REGULAR/STABLE), whose control planes can run versions as old
    as those still receiving upstream support; Kubernetes' relaxed search-path
    validation (RelaxedDNSSearchValidation) only reached GA in 1.34, so an
    older but still-supported cluster validates search domains strictly at
    admission and rejects the relaxed shapes (bare ".", underscores) even
    though a newer cluster would accept them. This variable validates to the
    stricter grammar every supported GKE release admits, rather than silently
    depending on the newer gate.

    At most 32 search entries totalling 2048 characters (joined by single
    spaces), matching the Kubernetes API server's own admission limit.

    DNS options must have unique names: the API server admits only one value
    per name, so a duplicate silently drops one entry rather than merging or
    erroring. The ndots option, if present, must carry a whole number from 0
    to 15 written as a string.
  EOT

  type = object({
    nameservers = optional(list(string))
    searches    = optional(list(string))
    options = optional(list(object({
      name  = string
      value = optional(string)
    })))
  })

  default = null

  # All guard-style conditions below are written as `guard ? body : true`
  # rather than `guard-inverted || body`, per AGENTS.md's consistency rule: the
  # null guard gates the attribute access structurally rather than relying on
  # short-circuit evaluation.
  validation {
    condition = var.n8n_dns_config == null ? true : (
      length(coalesce(var.n8n_dns_config.nameservers, [])) <= 3
    )
    error_message = "n8n_dns_config.nameservers accepts at most 3 entries: the Kubernetes pod spec rejects more, and the kubelet reports it as a pod-level validation failure rather than a Helm error, which is slow to diagnose."
  }

  validation {
    condition = var.n8n_dns_config == null ? true : alltrue([
      for ns in coalesce(var.n8n_dns_config.nameservers, []) :
      can(cidrhost("${ns}/32", 0)) || can(cidrhost("${ns}/128", 0))
    ])
    error_message = "n8n_dns_config.nameservers entries must each be a plain IPv4 or IPv6 address, without a port, prefix length, or hostname. The Kubernetes API server validates each entry as an IP at admission, so a malformed one otherwise surfaces as a rejected pod spec rather than a Helm error."
  }

  validation {
    condition = var.n8n_dns_config == null ? true : (
      length(coalesce(var.n8n_dns_config.searches, [])) <= 32 &&
      length(join(" ", coalesce(var.n8n_dns_config.searches, []))) <= 2048
    )
    error_message = "n8n_dns_config.searches accepts at most 32 entries totalling 2048 characters, measured joined by single spaces to match how the Kubernetes API server counts them at admission."
  }

  validation {
    condition = var.n8n_dns_config == null ? true : alltrue([
      for s in coalesce(var.n8n_dns_config.searches, []) :
      length(s) <= 253 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$", s))
    ])
    error_message = "n8n_dns_config.searches entries must each be a lowercase RFC 1123 subdomain of at most 253 characters: alphanumeric labels and hyphens only, no underscores, and no bare \".\" or trailing dot. Every supported GKE release admits this stricter grammar at admission; the relaxed rules (bare \".\", underscores) are only guaranteed on clusters running Kubernetes 1.34 or newer."
  }

  validation {
    condition = var.n8n_dns_config == null ? true : (
      length(distinct([for o in coalesce(var.n8n_dns_config.options, []) : o.name])) ==
      length(coalesce(var.n8n_dns_config.options, []))
    )
    error_message = "n8n_dns_config.options must not repeat the same option name. The Kubernetes API server admits only one value per name, so a duplicate silently drops one entry rather than merging or erroring, which looks like the setting worked while leaving resolution behaviour unchanged."
  }

  validation {
    # Ternaries, not `o.name != "ndots" || (... && can(regex(...)) &&
    # tonumber(o.value) ...)`: Terraform does not short-circuit &&/||, so
    # tonumber still runs (and errors, e.g. on "many") even when the regex
    # already rejected the value. Only a ternary's untaken branch is skipped.
    condition = var.n8n_dns_config == null ? true : alltrue([
      for o in coalesce(var.n8n_dns_config.options, []) :
      o.name != "ndots" ? true : (o.value == null ? false : (can(regex("^[0-9]+$", o.value)) ? tonumber(o.value) <= 15 : false))
    ])
    error_message = "n8n_dns_config: the ndots option must carry a whole number between 0 and 15, written as a string (\"1\", not \"1.5\"). glibc parses ndots with strtol and silently ignores a fractional, non-numeric, or out-of-range value, falling back to its default of 1, which looks like the setting worked while leaving resolution behaviour unchanged."
  }
}

# ── Cloud SQL PostgreSQL ─────────────────────────────────────────────────────────────

variable "create_postgres_instance" {
  description = "When true (the default), the module creates and manages a Cloud SQL PostgreSQL instance, its database, its user, and its Cloud SQL-specific IAM bindings. Set to false to use an external database; n8n_database_host and exactly one of n8n_database_password / n8n_database_password_secret_ref must then be supplied. Kept as a static boolean rather than inferred from n8n_database_host == null because count expressions cannot depend on values computed at apply time."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_database_host" {
  description = "External database host. Required when create_postgres_instance = false. Ignored otherwise. Use this to pass any external PostgreSQL host."
  type        = string
  default     = null

  validation {
    condition     = var.create_postgres_instance || var.n8n_database_host != null
    error_message = "n8n_database_host is required when create_postgres_instance = false."
  }
}

variable "n8n_database_password" {
  description = "Direct password for the external database specified by n8n_database_host. Exactly one of n8n_database_password or n8n_database_password_secret_ref is required when create_postgres_instance = false. Ignored otherwise (the module generates a random password for its managed Cloud SQL instance)."
  type        = string
  default     = null
  sensitive   = true
}

# The completeness/mutual-exclusivity condition below references both this
# variable and n8n_database_password, so it lives on exactly one of the two
# (here) rather than being duplicated on both: a validation block on each
# variable referencing the other would form a validation-graph cycle.
variable "n8n_database_password_secret_ref" {
  description = "Reference to an existing Kubernetes Secret (in the n8n namespace) holding the external database password, instead of passing the value directly through n8n_database_password. key defaults to \"password\" when omitted. The module never reads the referenced Secret's value; it only passes the reference through to the n8n Helm chart's database.passwordSecret. Exactly one of n8n_database_password or n8n_database_password_secret_ref is required when create_postgres_instance = false. Ignored otherwise."
  type = object({
    name = string
    key  = optional(string, "password")
  })
  default = null

  validation {
    condition = var.create_postgres_instance || (
      (var.n8n_database_password != null) != (var.n8n_database_password_secret_ref != null)
    )
    error_message = "Exactly one of n8n_database_password or n8n_database_password_secret_ref is required when create_postgres_instance = false."
  }
}

variable "db_postgresdb_pool_size" {
  description = "Maximum number of TypeORM connection pool slots per n8n pod. Pool connections are acquired lazily on demand, up to this ceiling, not held open continuously from startup; a pod that never reaches this many concurrent queries never opens this many connections. db_ping_timeout_ms/db_postgresdb_connection_timeout_ms bound how long a request waits to acquire a slot from this pool once it is exhausted. Rule of thumb: pool_size >= worker_concurrency / 4. With PgBouncer in transaction mode a lower value (5) is sufficient; without PgBouncer use a value matching concurrency (10-20)."
  type        = number
  default     = 10

  validation {
    condition     = var.db_postgresdb_pool_size >= 1
    error_message = "db_postgresdb_pool_size must be at least 1."
  }
}

variable "db_ping_timeout_ms" {
  description = "Milliseconds n8n waits for a database ping to respond before considering the connection unhealthy. Wired to DB_PING_TIMEOUT_MS on every n8n role (main, worker, webhook processor), for both managed Cloud SQL and external PostgreSQL. Null (the default) omits the override so n8n's own default applies."
  type        = number
  default     = null

  validation {
    condition     = var.db_ping_timeout_ms == null ? true : (var.db_ping_timeout_ms >= 1 && floor(var.db_ping_timeout_ms) == var.db_ping_timeout_ms)
    error_message = "db_ping_timeout_ms must be a positive whole number of milliseconds, or null to omit the override."
  }
}

variable "db_ping_interval_seconds" {
  description = "Seconds between database health-check pings. Wired to DB_PING_INTERVAL_SECONDS on every n8n role, for both managed Cloud SQL and external PostgreSQL. Null (the default) omits the override so n8n's own default applies."
  type        = number
  default     = null

  validation {
    condition     = var.db_ping_interval_seconds == null ? true : (var.db_ping_interval_seconds >= 1 && floor(var.db_ping_interval_seconds) == var.db_ping_interval_seconds)
    error_message = "db_ping_interval_seconds must be a positive whole number of seconds, or null to omit the override."
  }
}

variable "db_ping_max_failures_before_recovery" {
  description = "Number of consecutive failed database pings n8n tolerates before entering recovery. Wired to DB_PING_MAX_FAILURES_BEFORE_RECOVERY on every n8n role, for both managed Cloud SQL and external PostgreSQL. Null (the default) omits the override so n8n's own default applies."
  type        = number
  default     = null

  validation {
    condition     = var.db_ping_max_failures_before_recovery == null ? true : (var.db_ping_max_failures_before_recovery >= 1 && floor(var.db_ping_max_failures_before_recovery) == var.db_ping_max_failures_before_recovery)
    error_message = "db_ping_max_failures_before_recovery must be a positive whole count, or null to omit the override."
  }
}

variable "db_postgresdb_connection_timeout_ms" {
  description = "Milliseconds n8n waits to acquire a connection slot from db_postgresdb_pool_size before failing the request (TypeORM connection-acquisition timeout, distinct from db_ping_timeout_ms's health-check timeout). Wired to DB_POSTGRESDB_CONNECTION_TIMEOUT on every n8n role, for both managed Cloud SQL and external PostgreSQL. Zero disables this acquisition timeout. Null (the default) omits the override so n8n's own default applies."
  type        = number
  default     = null

  validation {
    condition     = var.db_postgresdb_connection_timeout_ms == null ? true : (var.db_postgresdb_connection_timeout_ms >= 0 && var.db_postgresdb_connection_timeout_ms <= 2147483647 && floor(var.db_postgresdb_connection_timeout_ms) == var.db_postgresdb_connection_timeout_ms)
    error_message = "db_postgresdb_connection_timeout_ms must be a whole number of milliseconds from 0 to 2147483647, or null to omit the override."
  }
}

variable "db_postgresdb_ssl_enabled" {
  description = "Whether n8n connects to the database over SSL. For Cloud SQL over Private Services Access the recommended default is false: the instance uses ssl_mode ALLOW_UNENCRYPTED_AND_ENCRYPTED and traffic stays on the VPC private network. Set to true to require SSL; certificate verification is skipped by default (DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false) unless db_postgresdb_ssl_reject_unauthorized is also set, which additionally validates the server certificate (see that variable's description for its create_postgres_instance = false restriction)."
  type        = bool
  default     = false
  nullable    = false
}

variable "db_postgresdb_ssl_reject_unauthorized" {
  description = "When true and db_postgresdb_ssl_enabled = true, n8n verifies the PostgreSQL server's certificate (DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=true) instead of the hardcoded false this module used before, which encrypted the connection but never validated the server certificate. node-postgres (n8n's driver) has no equivalent of libpq's chain-only verify-ca: enabling this performs the same full certificate-chain-plus-hostname check as PostgreSQL's verify-full, whichever name you think of it as. Restricted to create_postgres_instance = false (external PostgreSQL): the module connects to its own Cloud SQL instance by private IP, while Google documents Cloud SQL hostname verification only by DNS name (for example the instance DNS name with the shared CA server_ca_mode and a private DNS record, which this module does not set up), so n8n's hostname check is expected to fail the TLS handshake there. On the external path, point n8n_database_host at a hostname or IP address that matches a Subject Alternative Name in the external server's certificate for the hostname check to succeed, and supply the issuing CA via db_postgresdb_ssl_ca_pem unless the pod image's default trust store already trusts it. See docs/postgresql-tls.md."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = var.db_postgresdb_ssl_reject_unauthorized ? (var.db_postgresdb_ssl_enabled && !var.create_postgres_instance) : true
    error_message = "db_postgresdb_ssl_reject_unauthorized requires db_postgresdb_ssl_enabled = true (an unencrypted connection has no certificate to verify) and create_postgres_instance = false (the module connects to its own Cloud SQL instance by private IP, and Google documents Cloud SQL hostname verification only by DNS name, so n8n's hostname check is expected to fail there; see docs/postgresql-tls.md)."
  }
}

variable "db_postgresdb_ssl_ca_pem" {
  description = "PEM-encoded CA certificate bundle n8n trusts when db_postgresdb_ssl_reject_unauthorized = true. The module passes it, whitespace-trimmed, to the n8n Helm chart's database.ssl.ca value, which the chart renders into its own ConfigMap as DB_POSTGRESDB_SSL_CA for the main, worker, and webhook-processor pods. Because the CA is part of the Helm release, changing it rolls the pods (the chart's checksum/config annotation), and if a failed upgrade's atomic rollback succeeds, the previous CA is restored. Same input name as terraform-aws-n8n. A CA certificate is public, so it is not marked sensitive; it is stored in Terraform state and in the Helm release. Applies only to the external PostgreSQL path (create_postgres_instance = false) with db_postgresdb_ssl_reject_unauthorized = true; ignored, with a plan-time warning, otherwise. Leave null to fall back to the pod image's bundled trust store, which validates successfully only if the external server's certificate chains to a publicly trusted root CA; that fallback also follows Node's process-wide NODE_TLS_REJECT_UNAUTHORIZED setting. See docs/postgresql-tls.md."
  type        = string
  default     = null

  # Requires PEM certificate framing rather than only rejecting an empty
  # string, matching terraform-aws-n8n: a DER blob, a truncated download, or
  # plain text would otherwise only surface as a connection failure once n8n
  # tried to parse it. (?s) makes "." match newlines so a multi-certificate
  # bundle still matches end to end. This checks framing only, not the
  # certificate itself.
  validation {
    condition     = var.db_postgresdb_ssl_ca_pem == null ? true : can(regex("(?s)^\\s*-----BEGIN CERTIFICATE-----.*-----END CERTIFICATE-----\\s*$", var.db_postgresdb_ssl_ca_pem))
    error_message = "db_postgresdb_ssl_ca_pem must be null or a PEM-encoded CA bundle (containing -----BEGIN CERTIFICATE----- / -----END CERTIFICATE----- delimiters)."
  }
}

# ── Execution data storage ────────────────────────────────────────────────────

variable "n8n_execution_data_storage_mode" {
  description = "Where n8n stores the data of each new execution. Maps to N8N_EXECUTION_DATA_STORAGE_MODE. \"database\" (the default) keeps execution data in PostgreSQL, matching n8n's own default, and emits no env var. \"s3\" offloads it to the effective GCS S3-compatible storage contract this module already configures for binary data (the same bucket, HMAC identity, and Secret), so no extra bucket or credentials are needed. Requires n8n >= 2.27 (pin n8n_image_tag accordingly) and an Enterprise license carrying the feat:executionDataS3 entitlement, a different entitlement from the one binary data offload uses. There is no backfill: only new executions go to object storage. \"filesystem\" is not accepted: pod filesystems are ephemeral and unshared in this module's queue-mode topology."
  type        = string
  default     = "database"
  nullable    = false

  validation {
    condition     = contains(["database", "s3"], var.n8n_execution_data_storage_mode)
    error_message = "n8n_execution_data_storage_mode must be either \"database\" (n8n's default, execution data in PostgreSQL) or \"s3\" (execution data offloaded to the effective GCS storage contract). \"filesystem\" is not supported by this module: pod filesystems are ephemeral and unshared in queue mode."
  }
}

# ── HPA: main pods ────────────────────────────────────────────────────────────

variable "n8n_main_leader_election_enabled" {
  description = "Override runtime main leader election (N8N_MULTI_MAIN_SETUP_ENABLED). Null preserves count-based selection: disabled at one selected replica, enabled above one. Set true while holding the selected count at one to stage a single-main to multi-main conversion; Recreate, PDB minimum 0, and the managed HPA maximum of 1 remain in effect. Apply and verify that every election-disabled main has exited before separately increasing replicas. False is accepted only at one selected replica. At one replica, the chart keeps multiMain.enabled=false because it requires at least two replicas; the module instead injects the election flag through config.extraEnv on all n8n roles, rolling mains, workers, and webhook processors. Above one, the chart supplies its normal main-only election reference. Requires a license supporting multi-main when true. This input does not enforce ordering across applies; see docs/upgrading-n8n.md#returning-to-multi-main."
  type        = bool
  default     = null

  validation {
    condition = var.n8n_main_leader_election_enabled == false ? (
      (var.n8n_main_hpa_enabled ? var.n8n_main_hpa_min_replicas : var.n8n_main_fixed_replicas) == 1
    ) : true
    error_message = "n8n_main_leader_election_enabled may be false only when the selected main replica count is 1 (HPA minimum when enabled, fixed replicas otherwise)."
  }
}

variable "n8n_main_hpa_enabled" {
  description = "When true (the default), the module creates and manages the HPA for n8n main pods. Set to false to let the caller own main-pod scaling (or run a fixed replica count); no n8n main HPA is rendered. n8n_main_fixed_replicas sets the replica count while disabled. Unless n8n_main_leader_election_enabled overrides election, topology follows the selected count either way: n8n_main_hpa_min_replicas=1 (with this enabled) or n8n_main_fixed_replicas=1 (with this disabled) selects single-main; any larger selected count keeps the module's multi-main default. Single-main requires an n8n Enterprise license edition that supports it (not community edition) and interrupts the editor, REST API, and scheduled triggers during maintenance; it does not by itself grant External Secrets, log streaming, the custom package registry, or object-storage entitlements, and Recreate does not guarantee at-most-one execution after a manual pod deletion, node failure, or network partition. A caller-owned main scaler (this disabled) must not exceed one main until deliberately switching back to multi-main with the appropriate entitlement."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_main_fixed_replicas" {
  description = "Fixed replica count for n8n main pods when n8n_main_hpa_enabled = false. Ignored while the HPA is enabled. A value of 1 selects single-main topology by default; n8n_main_leader_election_enabled can stage election at this count without changing Recreate or PDB behavior. See n8n_main_hpa_enabled for licensing and maintenance implications."
  type        = number
  default     = 2

  validation {
    condition     = var.n8n_main_fixed_replicas >= 1 && floor(var.n8n_main_fixed_replicas) == var.n8n_main_fixed_replicas
    error_message = "n8n_main_fixed_replicas must be a whole number of at least 1."
  }
}

variable "n8n_main_hpa_min_replicas" {
  description = "Minimum replicas for n8n main pods. HPA will not scale below this. A value of 1 selects single-main topology by default; n8n_main_leader_election_enabled can stage election at this count while retaining Recreate, PDB minimum 0, and HPA maximum 1. See n8n_main_hpa_enabled for licensing and maintenance implications."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_min_replicas >= 1 && floor(var.n8n_main_hpa_min_replicas) == var.n8n_main_hpa_min_replicas
    error_message = "n8n_main_hpa_min_replicas must be a whole number of at least 1."
  }
}

variable "n8n_main_hpa_max_replicas" {
  description = "Maximum replicas for n8n main pods. Effectively clamped to 1 while n8n_main_hpa_min_replicas=1, even when leader election is explicitly enabled for staging. Before raising the minimum above 1 on an existing single-main deployment, separately apply and verify n8n_main_leader_election_enabled=true at one replica; see docs/upgrading-n8n.md#returning-to-multi-main. Ignored when n8n_main_hpa_enabled=false."
  type        = number
  default     = 20
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_max_replicas >= 1 && floor(var.n8n_main_hpa_max_replicas) == var.n8n_main_hpa_max_replicas
    error_message = "n8n_main_hpa_max_replicas must be a whole number of at least 1."
  }

  validation {
    condition     = var.n8n_main_hpa_max_replicas >= var.n8n_main_hpa_min_replicas
    error_message = "n8n_main_hpa_max_replicas must be greater than or equal to n8n_main_hpa_min_replicas."
  }
}

variable "n8n_main_hpa_cpu_threshold" {
  description = "Target average CPU utilization (%) that triggers scaling of n8n main pods."
  type        = number
  default     = 60
  nullable    = false

  validation {
    condition     = var.n8n_main_hpa_cpu_threshold >= 1 && var.n8n_main_hpa_cpu_threshold <= 100 && floor(var.n8n_main_hpa_cpu_threshold) == var.n8n_main_hpa_cpu_threshold
    error_message = "n8n_main_hpa_cpu_threshold must be a whole number between 1 and 100."
  }
}

# ── HPA: webhook processor pods ───────────────────────────────────────────────

variable "n8n_webhook_hpa_enabled" {
  description = "When true (the default), the module creates and manages the HPA for n8n webhook processor pods. Set to false to let the caller own webhook-pod scaling (or run a fixed replica count); no n8n webhook HPA is rendered. n8n_webhook_fixed_replicas sets the replica count while disabled."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_webhook_fixed_replicas" {
  description = "Fixed replica count for n8n webhook processor pods when n8n_webhook_hpa_enabled = false. Ignored while the HPA is enabled."
  type        = number
  default     = 2

  validation {
    condition     = var.n8n_webhook_fixed_replicas >= 1 && floor(var.n8n_webhook_fixed_replicas) == var.n8n_webhook_fixed_replicas
    error_message = "n8n_webhook_fixed_replicas must be a whole number of at least 1."
  }
}

variable "n8n_webhook_hpa_min_replicas" {
  description = "Minimum replicas for n8n webhook processor pods. HPA will not scale below this."
  type        = number
  default     = 2
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_min_replicas >= 1 && floor(var.n8n_webhook_hpa_min_replicas) == var.n8n_webhook_hpa_min_replicas
    error_message = "n8n_webhook_hpa_min_replicas must be a whole number of at least 1."
  }
}

variable "n8n_webhook_hpa_max_replicas" {
  description = "Maximum replicas for n8n webhook processor pods. HPA will not scale above this."
  type        = number
  default     = 50
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_max_replicas >= 1 && floor(var.n8n_webhook_hpa_max_replicas) == var.n8n_webhook_hpa_max_replicas
    error_message = "n8n_webhook_hpa_max_replicas must be a whole number of at least 1."
  }

  validation {
    condition     = var.n8n_webhook_hpa_max_replicas >= var.n8n_webhook_hpa_min_replicas
    error_message = "n8n_webhook_hpa_max_replicas must be greater than or equal to n8n_webhook_hpa_min_replicas."
  }
}

variable "n8n_webhook_hpa_cpu_threshold" {
  description = "Target average CPU utilization (%) that triggers scaling of n8n webhook pods."
  type        = number
  default     = 65
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_cpu_threshold >= 1 && var.n8n_webhook_hpa_cpu_threshold <= 100 && floor(var.n8n_webhook_hpa_cpu_threshold) == var.n8n_webhook_hpa_cpu_threshold
    error_message = "n8n_webhook_hpa_cpu_threshold must be a whole number between 1 and 100."
  }
}

variable "n8n_webhook_hpa_scale_up_stabilization_window_seconds" {
  description = "Seconds the standalone n8n webhook-processor HPA waits before acting on a scale-up recommendation, smoothing out rapidly fluctuating metric values. Maps to the HPA's behavior.scaleUp.stabilizationWindowSeconds. 0 (the default) matches Kubernetes' own scale-up default (react immediately); the chart's built-in main/worker scaling is unaffected. Ignored when n8n_webhook_hpa_enabled = false, since no webhook HPA is rendered in that case."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.n8n_webhook_hpa_scale_up_stabilization_window_seconds >= 0 && var.n8n_webhook_hpa_scale_up_stabilization_window_seconds <= 3600 && floor(var.n8n_webhook_hpa_scale_up_stabilization_window_seconds) == var.n8n_webhook_hpa_scale_up_stabilization_window_seconds
    error_message = "n8n_webhook_hpa_scale_up_stabilization_window_seconds must be a whole number of seconds between 0 and 3600."
  }
}

# ── License shutdown behavior ─────────────────────────────────────────────────

variable "n8n_license_detach_floating_on_shutdown" {
  description = "Whether n8n main pods detach their floating license entitlement on shutdown. Maps to N8N_LICENSE_DETACH_FLOATING_ON_SHUTDOWN. n8n's upstream default is true, which is safe for a single main but breaks multi-main (the module default, two main replicas): the leader main detaches on shutdown and zeroes the shared floating cert in the database, so any fresh main pod that starts as a follower reads the zeroed cert, fails the init-time license gate, and crash-loops, which can push a Helm release with atomic = true into a stuck pending-rollback state. The module defaults this to false, overriding n8n's own default, because all mains share the same device fingerprint: a single floating seat is reused across restarts and nothing leaks. Set to true only to restore n8n's upstream behavior, and only for single-main deployments."
  type        = bool
  default     = false
  nullable    = false
}

# ── Observability ─────────────────────────────────────────────────────────────

variable "n8n_metrics_enabled" {
  description = "Enable n8n's built-in Prometheus metrics endpoint. When true, the module appends N8N_METRICS=true to the n8n Helm release's config.extraEnv, which the chart applies to every n8n container (main, worker, webhook processor). n8n exposes /metrics on its existing HTTP port (5678), the same port and service the chart already publishes for the UI/API. The n8n Helm chart at the currently pinned version (see n8n_chart_version) exposes no top-level metrics / serviceMonitor block of its own, so this toggle is intentionally env-var-only. Scrape configuration (Prometheus scrape annotations or a ServiceMonitor CR) is left to the caller's monitoring stack, in practice the main pod's Service is the meaningful scrape target. Defaults to false; when false the env var is omitted entirely so n8n's own defaults apply."
  type        = bool
  default     = false
}

variable "n8n_templates_enabled" {
  description = "Enable n8n's workflow templates and template suggestions. Maps to N8N_TEMPLATES_ENABLED. When false, sets N8N_TEMPLATES_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default, note that explicitly setting true emits no env var (n8n's default already applies). Set to false to hide the templates library, e.g. when enforcing curated internal workflows."
  type        = bool
  default     = true
}

variable "n8n_personalization_enabled" {
  description = "Whether n8n asks users personalization survey questions and tailors content/recommendations based on the answers. Maps to N8N_PERSONALIZATION_ENABLED. When false, sets N8N_PERSONALIZATION_ENABLED=false on all n8n pods (main, worker, webhook processor) via config.extraEnv. Defaults to true, matching n8n's own default, note that explicitly setting true emits no env var (n8n's default already applies). Set to false to skip the personalization survey, e.g. on shared or ephemeral instances."
  type        = bool
  default     = true
}

# ── Community packages ────────────────────────────────────────────────────────

variable "n8n_reinstall_missing_packages" {
  description = "Reinstall community packages that are recorded in the database but missing from a pod's local filesystem at startup. Maps to N8N_REINSTALL_MISSING_PACKAGES. n8n stores installed community packages on the pod's filesystem, which is ephemeral in Kubernetes, so a rescheduled or newly scaled-up worker comes up without them and nodes installed via the UI fail to load on that pod. Enabling this makes every pod (main, worker, and webhook-processor) reinstall the recorded packages on boot, which is what lets community nodes work reliably in queue mode. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies."
  type        = bool
  default     = false
}

variable "n8n_community_packages_prevent_loading" {
  description = "Prevent installed community packages from being loaded at runtime. Maps to N8N_COMMUNITY_PACKAGES_PREVENT_LOADING. When true, n8n leaves the community-packages management surface in place but skips loading the package code, which is useful for locking an instance down without uninstalling. Leave false (the default) for community nodes to load and execute. n8n defaults this to false; when false the env var is omitted entirely so n8n's own default applies."
  type        = bool
  default     = false
}

# OpenTelemetry tracing
# Wired to N8N_OTEL_* env vars on the n8n Helm release's config.extraEnv block,
# which the chart applies to every n8n container (main, worker, webhook
# processor). This matches the n8n OpenTelemetry docs' queue-mode requirement:
# https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/
#
# The collector / Jaeger receiver itself is intentionally out of scope for this
# module, deploy it via a separate Terraform module (or directly) and point
# n8n_otel_exporter_otlp_endpoint at it.
#
# When n8n_otel_enabled = false (the default), no N8N_OTEL_* env vars are
# emitted at all and the OpenTelemetry SDK is not loaded. The individual tuning
# variables (endpoint, headers, service name, sample rate, span inclusion,
# outbound injection, production-only filtering) default to null, when an
# individual value is null the corresponding env var is omitted entirely so
# n8n's own default applies. Only set the values you actually need to override.

variable "n8n_otel_enabled" {
  description = "Master switch for n8n's OpenTelemetry workflow + node tracing. When true, the module sets N8N_OTEL_ENABLED=true on all n8n containers (main, worker, webhook processor) via the Helm release's config.extraEnv block. When false (the default), no OpenTelemetry env vars are emitted and the SDK is not loaded. The OpenTelemetry collector / Jaeger receiver is out of scope for this module, deploy it separately and point n8n_otel_exporter_otlp_endpoint at it. See https://docs.n8n.io/hosting/logging-monitoring/opentelemetry/ for the underlying n8n contract."
  type        = bool
  default     = false
}

variable "n8n_otel_exporter_otlp_endpoint" {
  description = "Base URL of the OTLP HTTP endpoint to export traces to (e.g. http://otel-collector.observability.svc.cluster.local:4318 for an in-cluster collector). When set, maps to N8N_OTEL_EXPORTER_OTLP_ENDPOINT. n8n appends /v1/traces to this value internally, so point at the base URL, not the traces path. Leave null to use n8n's default (http://localhost:4318), which only works if a sidecar collector is colocated in each n8n pod (this module does not deploy one). Ignored when n8n_otel_enabled = false."
  type        = string
  default     = null

  # Null-safe ternary (see n8n_otel_traces_sample_rate for the Terraform 1.9.x
  # short-circuit rationale): only validate the scheme when a value is set.
  validation {
    condition = var.n8n_otel_exporter_otlp_endpoint == null ? true : (
      startswith(var.n8n_otel_exporter_otlp_endpoint, "http://") ||
      startswith(var.n8n_otel_exporter_otlp_endpoint, "https://")
    )
    error_message = "n8n_otel_exporter_otlp_endpoint must be a base URL starting with http:// or https:// (n8n appends /v1/traces itself), or null to use n8n's default."
  }
}

variable "n8n_otel_exporter_otlp_headers" {
  description = "Comma-separated list of key=value pairs sent as HTTP headers with each OTLP request (e.g. 'authorization=Bearer <token>,x-tenant=acme'). Use this for collector authentication or multi-tenant routing. Maps to N8N_OTEL_EXPORTER_OTLP_HEADERS. Leave null to send no extra headers. Marked sensitive so the value is redacted from CLI and plan output, but note it is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). The chart's config.extraEnv does not support secretKeyRef, so restrict access to state and the n8n namespace accordingly. Ignored when n8n_otel_enabled = false."
  type        = string
  default     = null
  sensitive   = true
}

variable "n8n_otel_exporter_service_name" {
  description = "Value of the service.name resource attribute on exported spans. Maps to N8N_OTEL_EXPORTER_SERVICE_NAME. Leave null to use n8n's default ('n8n'). Set this to differentiate multiple n8n deployments sending traces to the same collector (e.g. 'n8n-prod', 'n8n-staging'). Ignored when n8n_otel_enabled = false."
  type        = string
  default     = null
}

variable "n8n_otel_traces_sample_rate" {
  description = "Fraction of traces to export, between 0 and 1 inclusive. Maps to N8N_OTEL_TRACES_SAMPLE_RATE. n8n uses a trace-ID-ratio sampler, so the same trace ID is either fully sampled or fully dropped across all spans. Leave null to use n8n's default (1.0, every trace exported). Lower for high-volume installs where the collector or backend can't handle every workflow execution as a trace. Ignored when n8n_otel_enabled = false."
  type        = number
  default     = null

  # Use a ternary rather than `null || numeric_op` here: Terraform 1.9.x
  # eagerly evaluates both sides of the logical OR during validation, so the
  # `null >= 0` branch errors with 'argument must not be null.' even when
  # the variable is null. Ternaries DO short-circuit, so wrapping the numeric
  # comparison in `var == null ? true : (...)` keeps the null path entirely
  # off the numeric-op branch.
  validation {
    condition = var.n8n_otel_traces_sample_rate == null ? true : (
      var.n8n_otel_traces_sample_rate >= 0 && var.n8n_otel_traces_sample_rate <= 1
    )
    error_message = "n8n_otel_traces_sample_rate must be between 0 and 1 inclusive, or null to use n8n's default."
  }
}

variable "n8n_otel_traces_include_node_spans" {
  description = "Whether to emit a node.execute span for each node execution. Maps to N8N_OTEL_TRACES_INCLUDE_NODE_SPANS. Leave null to use n8n's default (true, one span per node per execution). Set to false to export workflow-level spans only, a common volume-reduction lever for workflows with many small nodes. Ignored when n8n_otel_enabled = false."
  type        = bool
  default     = null
}

variable "n8n_otel_traces_inject_outbound" {
  description = "Whether n8n's HTTP-helper-based nodes (HTTP Request and similar) inject W3C traceparent / tracestate headers into outbound requests. Maps to N8N_OTEL_TRACES_INJECT_OUTBOUND. Leave null to use n8n's default (true, propagate context to downstream services). Set to false when calling external systems that misbehave on unexpected headers, or when you don't want trace context leaving your boundary. Ignored when n8n_otel_enabled = false."
  type        = bool
  default     = null
}

variable "n8n_otel_traces_production_only" {
  description = "Whether to export traces for production workflow executions only. Maps to N8N_OTEL_TRACES_PRODUCTION_ONLY. Leave null to use n8n's default (true, only production executions are traced). Set to false to also trace manual/test executions run from the editor, which helps while developing instrumentation but is noisy in production. Ignored when n8n_otel_enabled = false."
  type        = bool
  default     = null
}

# Log streaming (n8n Enterprise)
# Declaratively provisions log streaming destinations from environment
# variables using n8n's settings-env-vars activation pattern (n8n >= 2.19.0):
# https://docs.n8n.io/hosting/configuration/settings-env-vars/
#
# When n8n_log_streaming_managed_by_env = true, n8n reapplies the destinations
# from N8N_LOG_STREAMING_DESTINATIONS on every startup and locks the Log
# Streaming UI read-only. When false (the default), n8n ignores the env vars
# entirely and destinations are managed in the UI as usual. The feature itself
# is gated by the n8n Enterprise license (var.n8n_license_key), the license
# must include the log streaming entitlement.

variable "n8n_log_streaming_managed_by_env" {
  description = "Manage n8n's Enterprise log streaming destinations from environment variables instead of the UI. Maps to N8N_LOG_STREAMING_MANAGED_BY_ENV. When true, n8n applies n8n_log_streaming_destinations on every startup and locks the Log Streaming UI controls read-only. When false (the default), no log streaming env vars are emitted and destinations stay UI-managed; flipping back to false keeps the last applied destinations but restores UI write access. Requires n8n >= 2.19.0 and an Enterprise license that includes log streaming. See https://docs.n8n.io/log-streaming/ for the underlying n8n contract."
  type        = bool
  default     = false
}

variable "n8n_log_streaming_destinations" {
  description = "List of log streaming destination objects, JSON-encoded into N8N_LOG_STREAMING_DESTINATIONS. Each entry must set type to webhook, syslog, or sentry, plus the type-specific fields documented at https://docs.n8n.io/log-streaming/#configure-using-environment-variables (common fields: label, enabled, subscribedEvents, anonymizeAuditMessages, circuitBreaker). Typed as any because the three destination shapes differ structurally. Marked sensitive because webhook headers and Sentry DSNs typically carry credentials, note the value is still injected as a literal env var: it is persisted in plaintext in Terraform state and visible in the pod environment (kubectl describe / printenv). Ignored when n8n_log_streaming_managed_by_env = false."
  type        = any
  default     = []
  nullable    = false
  sensitive   = true

  validation {
    condition     = can([for d in var.n8n_log_streaming_destinations : d]) && !can(tostring(var.n8n_log_streaming_destinations))
    error_message = "n8n_log_streaming_destinations must be a list of destination objects (not a string, the module JSON-encodes it for you)."
  }

  validation {
    # Guarded with can() so a non-list value fails this validation cleanly
    # (via the list-shape validation above) instead of hard-erroring the
    # `for` expression during evaluation.
    condition = can([for d in var.n8n_log_streaming_destinations : d]) ? alltrue([
      for d in var.n8n_log_streaming_destinations :
      contains(["webhook", "syslog", "sentry"], try(d.type, "missing"))
    ]) : false
    error_message = "Each n8n_log_streaming_destinations entry must be an object with type set to one of: webhook, syslog, sentry."
  }
}

variable "n8n_extra_env" {
  description = "Additional environment variables to inject into all n8n pods (main, worker, and webhook-processor) via the Helm chart's config.extraEnv list. Each entry is an object with name and value string attributes. config.extraEnv is appended last in every container's env list, so by Kubernetes' last-wins rule any name here overrides the chart's value for that name. To prevent silently breaking the deployment, an entry is rejected at plan time when its name collides with a connection, identity, storage, license, or topology variable the module manages: any name starting with DB_, QUEUE_, N8N_RUNNERS_, N8N_EXTERNAL_STORAGE_S3_, N8N_MULTI_MAIN_, or AWS_, plus names like N8N_ENCRYPTION_KEY, N8N_LICENSE_ACTIVATION_KEY, N8N_HOST, N8N_WEBHOOK_URL, N8N_EDITOR_BASE_URL, and EXECUTIONS_MODE. Use the dedicated module inputs for those. Deprecated n8n variables (N8N_AVAILABLE_BINARY_DATA_MODES, WEBHOOK_URL) are rejected too: n8n logs a deprecation warning on every start while one is set, and the module already sets them itself where an older chart or image still needs them. Do not put secret values here, because they render into the Helm release and are stored in plaintext in Terraform state; instead pass a *_FILE companion (e.g. a name ending in _FILE) pointing at a mounted Kubernetes secret, or use n8n credentials. Example: [{name = \"N8N_DEFAULT_LOCALE\", value = \"de\"}]."
  type = list(object({
    name  = string
    value = string
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for e in var.n8n_extra_env : e.name != "" && e.name == trimspace(e.name)])
    error_message = "Each n8n_extra_env entry must have a non-empty name with no leading or trailing whitespace. Whitespace-padded names would bypass the duplicate and module-managed guards while rendering as a distinct, ignored env var."
  }

  validation {
    condition     = length(distinct([for e in var.n8n_extra_env : e.name])) == length(var.n8n_extra_env)
    error_message = "n8n_extra_env contains duplicate names; each environment variable may be set only once."
  }

  validation {
    condition = alltrue([
      for e in var.n8n_extra_env : !(
        contains(local.n8n_managed_env_names, e.name) ||
        anytrue([for p in local.n8n_managed_env_prefixes : startswith(e.name, p)])
      )
    ])
    error_message = "n8n_extra_env must not set module-managed variables. Reserved: any name starting with one of ${join(", ", local.n8n_managed_env_prefixes)} (connection/queue/runner/storage/topology/AWS families), plus the exact names ${join(", ", local.n8n_managed_env_names)}. config.extraEnv is appended last and would otherwise silently override these (Kubernetes last-wins). Use the dedicated module inputs (e.g. n8n_log_level, n8n_metrics_enabled) instead."
  }

  validation {
    condition     = !anytrue([for e in var.n8n_extra_env : contains(local.n8n_deprecated_env_names, e.name)])
    error_message = "n8n_extra_env must not set deprecated n8n variables (${join(", ", local.n8n_deprecated_env_names)}). n8n logs a deprecation warning on every start while one is set; remove the entry. For WEBHOOK_URL, set n8n_webhook_url instead: the module renders it as N8N_WEBHOOK_URL, and adds WEBHOOK_URL itself whenever the image tags do not prove n8n 2.30.0 or newer."
  }
}

# ── KEDA: worker pods ─────────────────────────────────────────────────────────

variable "n8n_worker_keda_enabled" {
  description = "When true (the default), the module creates and manages the KEDA ScaledObject for n8n worker pods. Set to false to let the caller own worker scaling (or run a fixed replica count); no n8n worker ScaledObject is rendered. n8n_worker_fixed_replicas sets the replica count while disabled."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_worker_fixed_replicas" {
  description = "Fixed replica count for n8n worker pods when n8n_worker_keda_enabled = false. Ignored while KEDA scaling is enabled."
  type        = number
  default     = 1

  validation {
    condition     = var.n8n_worker_fixed_replicas >= 1 && floor(var.n8n_worker_fixed_replicas) == var.n8n_worker_fixed_replicas
    error_message = "n8n_worker_fixed_replicas must be a whole number of at least 1."
  }
}

variable "n8n_worker_keda_min_replicas" {
  description = "Minimum worker replicas. KEDA keeps at least this many workers running even when the queue is empty."
  type        = number
  default     = 1
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_min_replicas >= 1 && floor(var.n8n_worker_keda_min_replicas) == var.n8n_worker_keda_min_replicas
    error_message = "n8n_worker_keda_min_replicas must be a whole number of at least 1."
  }
}

variable "n8n_worker_keda_max_replicas" {
  description = "Maximum worker replicas KEDA may scale to."
  type        = number
  default     = 10
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_max_replicas >= 1 && floor(var.n8n_worker_keda_max_replicas) == var.n8n_worker_keda_max_replicas
    error_message = "n8n_worker_keda_max_replicas must be a whole number of at least 1."
  }

  validation {
    condition     = var.n8n_worker_keda_max_replicas >= var.n8n_worker_keda_min_replicas
    error_message = "n8n_worker_keda_max_replicas must be greater than or equal to n8n_worker_keda_min_replicas."
  }
}

variable "n8n_worker_keda_pause" {
  description = "Pause KEDA autoscaling of the worker Deployment. Maps to the chart's keda.worker.pause, which annotates the worker ScaledObject with autoscaling.keda.sh/paused=true so KEDA stops reconciling and the workers hold their current replica count (or n8n_worker_keda_paused_replica_count while that is set). Use it for a maintenance window or before a migration without disabling KEDA; set back to false to resume, and KEDA scales to the queue depth again on its next poll. No effect when n8n_worker_keda_enabled = false. Requires n8n_chart_version 1.13.0 or newer: older charts ignore the key, and 1.12.0 re-renders the worker replica count on every Helm upgrade, overriding the held count (check.worker_keda_pause_requires_a_supported_chart warns). Pauses only the default worker Deployment; n8n_worker_pools pools keep scaling on their own ScaledObjects. The chart's matching webhook-processor pause is not exposed: this module scales webhook processors with its own HorizontalPodAutoscaler (scaling.tf), not a chart ScaledObject, so there is nothing for that annotation to act on. Same input name and semantics as terraform-aws-n8n and terraform-azurerm-n8n."
  type        = bool
  default     = false
  nullable    = false
}

variable "n8n_worker_keda_paused_replica_count" {
  description = "Replica count to hold the worker Deployment at while n8n_worker_keda_pause = true. Maps to the chart's keda.worker.pausedReplicaCount (the autoscaling.keda.sh/paused-replicas annotation). Null (the default) freezes the workers at whatever count they had when paused; 0 scales them to zero, e.g. to stop consuming jobs while they queue in Redis ahead of a migration. Scaling down does not wait for running executions beyond n8n's graceful shutdown window (N8N_GRACEFUL_SHUTDOWN_TIMEOUT, 30 seconds by default, overridable via n8n_graceful_shutdown_timeout), so let active work finish first. Ignored by the chart unless n8n_worker_keda_pause is true (check.worker_keda_paused_replica_count_requires_pause warns about that combination). Same input name and semantics as terraform-aws-n8n and terraform-azurerm-n8n."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_worker_keda_paused_replica_count == null ? true : (var.n8n_worker_keda_paused_replica_count >= 0 && floor(var.n8n_worker_keda_paused_replica_count) == var.n8n_worker_keda_paused_replica_count)
    error_message = "n8n_worker_keda_paused_replica_count must be a whole number of at least 0 (0 scales the paused workers to zero), or null to hold the current count."
  }
}

variable "n8n_worker_keda_jobs_per_replica" {
  description = "Number of waiting jobs per worker replica used as the KEDA scaling threshold. KEDA targets ceil(queue_depth / jobs_per_replica) replicas."
  type        = number
  default     = 5
  nullable    = false

  validation {
    condition     = var.n8n_worker_keda_jobs_per_replica >= 1 && floor(var.n8n_worker_keda_jobs_per_replica) == var.n8n_worker_keda_jobs_per_replica
    error_message = "n8n_worker_keda_jobs_per_replica must be a whole number of at least 1."
  }
}

# ── Worker pools (EARLY ALPHA) ─────────────────────────────────────────────────
# Tracks n8n's own worker pools feature and the chart support for it, both
# alpha upstream. See worker-pools.tf for the full caveat and the guard that
# fails the plan when n8n_chart_version cannot be trusted to render
# queueMode.workerGroups.

variable "n8n_worker_extra_env" {
  description = "Additional environment variables injected into worker pods only, via queueMode.workerExtraEnv. Use this for worker-only tuning that must not reach main or webhook-processor pods; n8n_extra_env is the equivalent for all three. This reaches every worker, the chart's own unlabelled deployment and each n8n_worker_pools pool alike, because they render from one shared pod template; a pool's own extra_env is applied after this and wins on a repeated name. N8N_WORKER_POOL_NAME is rejected here along with the other module-managed names: pool membership is owned by n8n_worker_pools, and pinning the chart's own worker deployment to a pool through this input would leave those workers consuming a pool queue that nothing scales. Rejected at plan time for the same module-managed and deprecated names as n8n_extra_env."
  type = list(object({
    name  = string
    value = string
  }))
  default  = []
  nullable = false

  validation {
    condition     = alltrue([for e in var.n8n_worker_extra_env : e.name != "" && e.name == trimspace(e.name)])
    error_message = "Each n8n_worker_extra_env entry must have a non-empty name with no leading or trailing whitespace."
  }

  validation {
    condition     = length(distinct([for e in var.n8n_worker_extra_env : e.name])) == length(var.n8n_worker_extra_env)
    error_message = "n8n_worker_extra_env contains duplicate names; each environment variable may be set only once."
  }

  validation {
    # C_IDENTIFIER, which is what Kubernetes requires of an env var name.
    # Applied here and to the pool extra_env because both are new here;
    # n8n_extra_env is deliberately left alone, since tightening an input
    # callers already use would turn a working configuration into a
    # plan-time failure on upgrade.
    condition     = alltrue([for e in var.n8n_worker_extra_env : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", e.name))])
    error_message = "Each n8n_worker_extra_env name must be a valid Kubernetes environment variable name: letters, digits and underscores only, not starting with a digit (for example N8N_LOG_LEVEL). Hyphens, dots and leading digits are rejected by the API server when the pod template is admitted."
  }

  validation {
    condition = alltrue([
      for e in var.n8n_worker_extra_env : !(
        contains(local.n8n_managed_env_names, e.name) ||
        anytrue([for p in local.n8n_managed_env_prefixes : startswith(e.name, p)])
      )
    ])
    error_message = "n8n_worker_extra_env must not set module-managed variables. Reserved: any name starting with one of ${join(", ", local.n8n_managed_env_prefixes)}, plus the exact names ${join(", ", local.n8n_managed_env_names)}. Use the dedicated module inputs instead."
  }

  validation {
    condition     = !anytrue([for e in var.n8n_worker_extra_env : contains(local.n8n_deprecated_env_names, e.name)])
    error_message = "n8n_worker_extra_env must not set deprecated n8n variables (${join(", ", local.n8n_deprecated_env_names)}). n8n logs a deprecation warning on every start while one is set; remove the entry. For WEBHOOK_URL, set n8n_webhook_url instead: the module renders it as N8N_WEBHOOK_URL, and adds WEBHOOK_URL itself whenever the image tags do not prove n8n 2.30.0 or newer."
  }
}

variable "n8n_worker_pools" {
  description = "EARLY ALPHA, SUBJECT TO CHANGE WITHOUT NOTICE: tracks n8n's own worker pools feature and the chart support for it, both alpha upstream. Labelled worker pools to run beside the chart's own unlabelled worker deployment. Each entry becomes one queueMode.workerGroups entry in the Helm release, which renders one Deployment (identical to the chart's worker pods but carrying N8N_WORKER_POOL_NAME) and one KEDA ScaledObject watching that pool's own `jobs-<name>` queue, so a pool autoscales on its own backlog rather than the default queue's. Requires n8n_worker_keda_enabled = true (the chart renders pool ScaledObjects only under release-wide KEDA scaling; see the validation on this variable). Requires an n8n_chart_version whose chart supports queueMode.workerGroups: that feature (n8n-io/n8n-hosting#189) is merged to the chart's preview/worker-pools branch but not released to a numbered chart version, and an older chart accepts the key and renders nothing for it, so a precondition on the Helm release fails the plan for every chart version except a worker-pools preview build (a prerelease whose identifier contains \"workerpools\", taken at the caller's word) or one attested with n8n_worker_pools_chart_verified. Pools share the default worker's Redis TriggerAuthentication (n8n-redis-auth), so managed Memorystore AUTH and transit encryption work for pools the same way they do for the default worker. An official preview build can be published from that branch's Preview chart GitHub Action to oci://ghcr.io/n8n-io/n8n-helm-chart, this module's default n8n_chart_repository, at a version such as 1.11.0-preview.workerpools.1, which is what to pin in n8n_chart_version. See examples/worker-pools/README.md for the exact command and a private-mirror fallback."
  type = list(object({
    name         = string
    min_replicas = optional(number, 1)
    max_replicas = optional(number, 5)

    # Null inherits the module-wide worker setting of the same name.
    concurrency    = optional(number, null)
    cpu_request    = optional(string, null)
    cpu_limit      = optional(string, null)
    memory_request = optional(string, null)
    memory_limit   = optional(string, null)

    # Extra env for this pool's workers only, on top of what every worker gets.
    extra_env = optional(list(object({
      name  = string
      value = string
    })), [])
  }))
  default  = []
  nullable = false

  validation {
    # 43, not the chart schema's 53: helm_release.n8n fixes the release name to
    # "n8n", so the chart names the pool's ScaledObject n8n-worker-<name> and
    # fails the render when that exceeds KEDA's 54-character cap. The schema's
    # 53 only holds for a release name short enough to leave room, which this
    # module's is not.
    condition     = alltrue([for p in var.n8n_worker_pools : can(regex("^[a-z0-9]([a-z0-9-]{0,41}[a-z0-9])?$", p.name))])
    error_message = "Each n8n_worker_pools name must be 1-43 characters of lowercase letters, digits and hyphens, starting and ending with a letter or digit. Uppercase and underscores are rejected by n8n's own schema (for example \"ITop\" or \"sec_team\" are invalid; use \"itop\" and \"sec-team\"). This is enforced here because n8n only logs a warning for a bad name and then starts the worker on the default queue anyway, so the pod reports healthy while serving the wrong jobs. The 43-character ceiling comes from KEDA: the chart names the pool's ScaledObject n8n-worker-<name>, KEDA caps that at 54 characters, and the chart fails the render past it. A value that passes here but not there fails at apply instead of at plan."
  }

  validation {
    condition     = alltrue([for p in var.n8n_worker_pools : p.name != "default"])
    error_message = "\"default\" is not a usable n8n_worker_pools name. A pool called \"default\" would listen to a queue literally named `jobs-default`, which is a separate queue from the unlabelled default `jobs` queue and would not receive the work you expect. The chart's own worker deployment already serves the default queue; size it with n8n_worker_keda_min_replicas and n8n_worker_keda_max_replicas instead."
  }

  validation {
    condition     = length(distinct([for p in var.n8n_worker_pools : p.name])) == length(var.n8n_worker_pools)
    error_message = "n8n_worker_pools contains duplicate pool names. Each pool maps to one Deployment and one queue, so a repeated name would collide on both."
  }

  validation {
    condition     = alltrue([for p in var.n8n_worker_pools : p.min_replicas <= p.max_replicas])
    error_message = "Each n8n_worker_pools entry must have min_replicas <= max_replicas; KEDA rejects a ScaledObject whose minReplicaCount is above its maxReplicaCount."
  }

  validation {
    condition = alltrue([
      for p in var.n8n_worker_pools :
      p.min_replicas == floor(p.min_replicas) && p.min_replicas >= 0 &&
      p.max_replicas == floor(p.max_replicas) && p.max_replicas >= 1
    ])
    error_message = "Each n8n_worker_pools entry needs whole-number replica bounds, with min_replicas >= 0 and max_replicas >= 1. KEDA scales a pool to zero natively, so 0 is a valid floor. Start a new pool at min_replicas = 1, assign its projects, then lower it to 0; n8n only offers a pool for assignment while at least one of its workers is registered, so a brand-new pool declared at 0 never receives work until it has scaled up at least once."
  }

  validation {
    condition     = alltrue([for p in var.n8n_worker_pools : p.concurrency == null ? true : (p.concurrency == floor(p.concurrency) && p.concurrency >= 1)])
    error_message = "n8n_worker_pools concurrency must be a whole number of concurrent jobs, 1 or greater, or null to inherit n8n_worker_concurrency."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for e in p.extra_env : !(
          contains(local.n8n_managed_env_names, e.name) ||
          anytrue([for pre in local.n8n_managed_env_prefixes : startswith(e.name, pre)]) ||
          e.name == "N8N_WORKER_POOL_NAME"
        )
      ]
    ]))
    error_message = "n8n_worker_pools extra_env must not set module-managed variables, and must not set N8N_WORKER_POOL_NAME: that name is owned by the pool's own `name` attribute, and overriding it would put the pool's workers on a different queue than the one this module creates a scaler for."
  }

  validation {
    condition = !anytrue(flatten([
      for p in var.n8n_worker_pools : [
        for e in p.extra_env : contains(local.n8n_deprecated_env_names, e.name)
      ]
    ]))
    error_message = "n8n_worker_pools extra_env must not set deprecated n8n variables (${join(", ", local.n8n_deprecated_env_names)}). n8n logs a deprecation warning on every start while one is set; remove the entry. For WEBHOOK_URL, set n8n_webhook_url instead: the module renders it as N8N_WEBHOOK_URL, and adds WEBHOOK_URL itself whenever the image tags do not prove n8n 2.30.0 or newer."
  }

  validation {
    # Same grammar the module-wide n8n_worker_cpu_* inputs enforce (capacity.tf's
    # parser only supports a bare core count or an m-suffixed millicore count).
    # A pool quantity capacity.tf cannot parse silences the whole capacity
    # check, not only the pool that carries it.
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for q in [p.cpu_request, p.cpu_limit] :
        q == null ? true : can(regex("^[0-9]+(\\.[0-9]+)?m?$", q))
      ]
    ]))
    error_message = "Each n8n_worker_pools cpu_request and cpu_limit must be a bare core count (e.g. \"1\") or a millicore count suffixed with m (e.g. \"500m\"), the only CPU quantity grammar capacity.tf's parser supports, or null to inherit n8n_worker_cpu_request / n8n_worker_cpu_limit."
  }

  validation {
    # Same grammar the module-wide n8n_worker_memory_* inputs enforce.
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for q in [p.memory_request, p.memory_limit] :
        q == null ? true : can(regex("^[0-9]+(\\.[0-9]+)?(Ki|Mi|Gi)?$", q))
      ]
    ]))
    error_message = "Each n8n_worker_pools memory_request and memory_limit must be a bare byte count or a quantity suffixed with Ki, Mi, or Gi (e.g. \"2Gi\"), the only memory quantity grammar capacity.tf's parser supports, or null to inherit n8n_worker_memory_request / n8n_worker_memory_limit."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for e in p.extra_env : e.name != "" && e.name == trimspace(e.name)
      ]
    ]))
    error_message = "n8n_worker_pools extra_env entries must each have a non-empty name with no leading or trailing whitespace. A padded name would bypass the duplicate and module-managed guards while rendering as a distinct, ignored env var."
  }

  validation {
    condition = alltrue([
      for p in var.n8n_worker_pools :
      length(distinct([for e in p.extra_env : e.name])) == length(p.extra_env)
    ])
    error_message = "An n8n_worker_pools entry has duplicate extra_env names. Within one pool each variable may be set once; a repeat is silently dropped by the last-wins merge rather than reported."
  }

  validation {
    condition = alltrue(flatten([
      for p in var.n8n_worker_pools : [
        for e in p.extra_env : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", e.name))
      ]
    ]))
    error_message = "Each n8n_worker_pools extra_env name must be a valid Kubernetes environment variable name: letters, digits and underscores only, not starting with a digit (for example N8N_LOG_LEVEL). Hyphens, dots and leading digits are rejected by the API server when the pod template is admitted."
  }

  validation {
    # The chart renders a pool's ScaledObject only while the release-wide
    # keda.enabled (n8n.tf, from this variable) is true, and its pool
    # Deployment falls back to 1 replica when no scaler owns the count, so
    # with KEDA off every pool would silently ignore min_replicas and
    # max_replicas. Both operands are always known booleans, so this `||` is
    # safe under the CI-pinned Terraform 1.9.x (see AGENTS.md).
    condition     = length(var.n8n_worker_pools) == 0 || var.n8n_worker_keda_enabled
    error_message = "n8n_worker_pools requires n8n_worker_keda_enabled = true. The chart renders a pool's KEDA ScaledObject only when release-wide KEDA scaling is on; otherwise each pool runs as a plain Deployment at 1 replica regardless of its min_replicas and max_replicas. Enable KEDA for workers, or remove the pools."
  }
}

variable "n8n_worker_pools_chart_verified" {
  description = "Attests that n8n_chart_version, whatever repository it resolves from, renders queueMode.workerGroups. Only consulted when n8n_worker_pools is non-empty and n8n_chart_version is not a worker-pools preview build; a prerelease whose SemVer 2 \"-\" identifier contains \"workerpools\" (e.g. 1.11.0-preview.workerpools.1) is already taken at your word from the version string itself and needs no extra input. This exists for the versions that string cannot vouch for: a numbered release or a generic prerelease (e.g. 1.12.0-rc.1) served from a private mirror that you have already built with the feature baked in, so you would rather not retag your own build. Setting this to true is a one-time promise, not an automated guarantee: nothing re-checks it if n8n_chart_version later changes to point at a different, unverified chart, so treat a bump to this variable's pinned version with the same scrutiny as setting this flag the first time. Leave it false once a real numbered floor replaces this guard entirely."
  type        = bool
  default     = false
  nullable    = false
}

# ── External Secrets and Google Secret Manager ────────────────────────────────
# D7: n8n's generic External Secrets feature (vault-provider connections
# configured in-product) is a separate concern from Google Secret Manager
# access for the n8n Workload Identity service account. The master switch
# below only turns the n8n *feature* on or off; it does not configure a vault
# provider. n8n_secret_manager_* grants IAM so a Google Secret Manager vault
# provider configured in n8n can actually read secrets, scoped to an explicit,
# wildcard-free allow-list, never project-wide.

variable "n8n_external_secrets_enabled" {
  description = "Master switch for n8n's External Secrets feature (vault-provider connections configured in Settings > External Secrets). When true (the default, matching n8n's own default), the feature is available. When false, the module adds \"external-secrets\" to N8N_DISABLED_MODULES on every n8n pod, disabling the feature entirely."
  type        = bool
  default     = true
  nullable    = false
}

variable "n8n_external_secrets_update_interval" {
  description = "Seconds between checks for updates to resolved external secret values. Maps to N8N_EXTERNAL_SECRETS_UPDATE_INTERVAL. Leave null (the default) to use n8n's own default (300s). Ignored when n8n_external_secrets_enabled = false."
  type        = number
  default     = null

  validation {
    condition     = var.n8n_external_secrets_update_interval == null ? true : var.n8n_external_secrets_update_interval > 0
    error_message = "n8n_external_secrets_update_interval must be a positive number of seconds, or null to use n8n's default."
  }
}

variable "n8n_secret_manager_enabled" {
  description = "When true, the module grants the n8n Workload Identity Google service account roles/secretmanager.secretAccessor on every secret listed in n8n_secret_manager_secret_ids, scoped to those secrets only (never project-wide). Requires a non-empty n8n_secret_manager_secret_ids. Configuring n8n's Google Secret Manager vault-provider connection itself (Settings > External Secrets) remains an in-product operator action; this only grants the underlying GCP IAM that connection needs. Defaults to false (no Secret Manager IAM granted)."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.n8n_secret_manager_enabled || length(var.n8n_secret_manager_secret_ids) > 0
    error_message = "n8n_secret_manager_secret_ids must be a non-empty allow-list when n8n_secret_manager_enabled = true; the module grants no project-wide Secret Manager access."
  }
}

variable "n8n_secret_manager_secret_ids" {
  description = "Explicit allow-list of Google Secret Manager secret resource IDs (format projects/<project>/secrets/<secret_id>) the n8n Workload Identity service account may read. Required (non-empty) when n8n_secret_manager_enabled = true. Ignored otherwise. Each entry must be a fully qualified secret resource ID with no wildcard, whitespace, or version suffix (IAM is granted at the secret level, not a specific version)."
  type        = list(string)
  default     = []
  nullable    = false

  validation {
    condition = alltrue([
      for id in var.n8n_secret_manager_secret_ids : can(regex("^projects/[^/[:space:]*]+/secrets/[^/[:space:]*]+$", id))
    ])
    error_message = "Each n8n_secret_manager_secret_ids entry must be a fully qualified secret resource ID in the form projects/<project>/secrets/<secret_id>, with no wildcard (*), whitespace, or /versions/... suffix."
  }
}
