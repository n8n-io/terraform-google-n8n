# ── Controllers submodule (modules/controllers) ───────────────────────────────
# Installs KEDA and the optional pd-balanced StorageClass. Extracted into a
# directly consumable public submodule (D6); the root module invokes it by
# default so a single `terraform apply` from an example root still installs
# everything.
#
# Install ordering: depends_on the node pool so scheduling capacity exists
# before the KEDA operator (and the pd-balanced StorageClass, which has no
# real ordering requirement but is grouped here) is created.
#
# Destroy ordering: helm_release.n8n depends_on this module, so during destroy
# the n8n release (including its ScaledObjects) is deleted FIRST while the KEDA
# operator is still running. KEDA processes the ScaledObject deletions and
# removes its own "finalizer.keda.sh" finalizer. KEDA is then uninstalled only
# after all ScaledObjects are gone (no orphaned finalizers). See
# modules/controllers/examples/direct-use for the same ordering contract
# expressed by a caller that composes the submodule directly.
module "controllers" {
  source = "./modules/controllers"

  install_keda          = var.install_keda
  keda_chart_repository = var.keda_chart_repository
  keda_chart_version    = var.keda_chart_version
  keda_namespace        = "keda"
  keda_helm_timeout     = 300

  create_pd_balanced_storage_class = var.create_pd_balanced_storage_class
  pd_balanced_storage_class_name   = "n8n-pd-balanced"
  common_labels                    = local.gcp_labels

  depends_on = [google_container_node_pool.n8n]
}
