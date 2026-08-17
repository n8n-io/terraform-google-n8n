output "keda_installed" {
  description = "Whether this submodule installed the KEDA Helm release (mirrors var.install_keda)."
  value       = var.install_keda
}

output "keda_namespace" {
  description = "Namespace KEDA is installed into, or null when install_keda = false."
  value       = var.install_keda ? helm_release.keda[0].namespace : null
}

output "keda_release_name" {
  description = "Name of the KEDA Helm release, or null when install_keda = false."
  value       = var.install_keda ? helm_release.keda[0].name : null
}

output "keda_chart_version" {
  description = "KEDA Helm chart version installed, or null when install_keda = false."
  value       = var.install_keda ? helm_release.keda[0].version : null
}

output "pd_balanced_storage_class_name" {
  description = "Name of the pd-balanced StorageClass, or null when create_pd_balanced_storage_class = false."
  value       = var.create_pd_balanced_storage_class ? kubernetes_storage_class_v1.pd_balanced[0].metadata[0].name : null
}
