# ── Cluster storage: GCE Persistent Disk CSI StorageClass ─────────────────────
# Multi-main n8n is itself stateless (Cloud SQL + GCS replace any PVC). GKE ships
# the pd.csi.storage.gke.io driver and default classes (standard-rwo,
# premium-rwo) out of the box, so no CSI addon is needed. This defines an
# explicit balanced-PD class for any stateful workload a user runs beside n8n.
# It is intentionally NOT marked default (GKE's standard-rwo stays the
# default), so it is additive and never fights the built-ins.

resource "kubernetes_storage_class_v1" "pd_balanced" {
  count = var.create_pd_balanced_storage_class ? 1 : 0

  metadata {
    name   = var.pd_balanced_storage_class_name
    labels = var.common_labels
  }

  storage_provisioner    = "pd.csi.storage.gke.io"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "pd-balanced"
  }
}
