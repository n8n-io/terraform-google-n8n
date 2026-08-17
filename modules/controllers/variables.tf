# ── KEDA ──────────────────────────────────────────────────────────────────────

variable "install_keda" {
  description = "When true (the default), this submodule installs and manages the KEDA Helm release. Set to false to use an existing KEDA installation (a compatible operator and CRDs already present on the cluster); no KEDA Helm release is rendered."
  type        = bool
  default     = true
  nullable    = false
}

variable "keda_namespace" {
  description = "Kubernetes namespace KEDA is installed into. Created automatically by the Helm release. Ignored when install_keda = false."
  type        = string
  default     = "keda"
  nullable    = false
}

variable "keda_chart_repository" {
  description = "Helm chart repository KEDA is installed from. Accepts an HTTPS chart-repository URL or an OCI registry reference (oci://...), so a private mirror can replace the public kedacore charts. Ignored when install_keda = false."
  type        = string
  default     = "https://kedacore.github.io/charts"
  nullable    = false

  validation {
    condition     = startswith(var.keda_chart_repository, "https://") || startswith(var.keda_chart_repository, "oci://")
    error_message = "keda_chart_repository must start with https:// or oci://."
  }
}

variable "keda_chart_version" {
  description = "KEDA Helm chart version to deploy. Pinned so every apply installs the same operator version; bump deliberately and re-run the test suite rather than floating to latest. Must be an exact semantic version. Ignored when install_keda = false."
  type        = string
  default     = "2.20.1"

  validation {
    condition     = can(regex("^\\d+\\.\\d+\\.\\d+(-[0-9A-Za-z-.]+)?(\\+[0-9A-Za-z-.]+)?$", var.keda_chart_version))
    error_message = "keda_chart_version must be an exact semantic version, e.g. \"2.20.1\" (optionally with a -prerelease or +build suffix). Version ranges (~>, >=) and floating tags (latest) are not accepted."
  }
}

variable "keda_helm_timeout" {
  description = "Seconds Terraform waits for the KEDA Helm release to converge. Ignored when install_keda = false."
  type        = number
  default     = 300

  validation {
    condition     = var.keda_helm_timeout >= 60
    error_message = "keda_helm_timeout must be at least 60 seconds."
  }
}

# ── Persistent-disk StorageClass ──────────────────────────────────────────────

variable "create_pd_balanced_storage_class" {
  description = "When true (the default), this submodule creates an explicit pd-balanced StorageClass for stateful workloads that run beside n8n (n8n itself is stateless). Set to false to omit it, e.g. when the caller already defines an equivalent StorageClass."
  type        = bool
  default     = true
  nullable    = false
}

variable "pd_balanced_storage_class_name" {
  description = "Name of the pd-balanced StorageClass. Ignored when create_pd_balanced_storage_class = false."
  type        = string
  default     = "n8n-pd-balanced"
  nullable    = false
}

# ── Common ─────────────────────────────────────────────────────────────────────

variable "common_labels" {
  description = "Common labels merged into the StorageClass this submodule creates. Ignored when create_pd_balanced_storage_class = false."
  type        = map(string)
  default     = {}
  nullable    = false
}
