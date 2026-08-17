output "keda_installed" {
  description = "Whether the controllers submodule installed KEDA."
  value       = module.controllers.keda_installed
}

output "pd_balanced_storage_class_name" {
  description = "Name of the pd-balanced StorageClass the controllers submodule created."
  value       = module.controllers.pd_balanced_storage_class_name
}
