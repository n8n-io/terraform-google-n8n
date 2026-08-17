# Direct-use example: composing modules/controllers with a separately managed
# n8n deployment, instead of going through the terraform-google-n8n root
# module. Demonstrates the explicit dependency ordering a direct caller must
# provide (controller-module spec, "Controller submodule is used directly"):
#
#   - Install:  KEDA (this module) must exist before n8n's ScaledObjects, so
#               the caller's n8n release depends_on module.controllers.
#   - Destroy:  n8n (and its ScaledObjects) must be removed before KEDA is
#               uninstalled, which the same depends_on also guarantees:
#               Terraform destroys in reverse dependency order, so the
#               dependent n8n release is destroyed first.

module "controllers" {
  source = "../.."

  install_keda                     = true
  create_pd_balanced_storage_class = true
}

# Stand-in for a separately managed n8n Helm release (in place of the
# terraform-google-n8n root module's own n8n.tf). The depends_on is the only
# wiring this example exists to demonstrate; the release's chart values are
# illustrative, not a supported configuration surface of this submodule.
resource "helm_release" "n8n" {
  name             = "n8n"
  repository       = "https://n8n-io.github.io/n8n-hosting"
  chart            = "n8n"
  version          = "1.10.1"
  namespace        = "n8n"
  create_namespace = true

  values = [yamlencode({
    n8n = {
      host = var.n8n_fqdn
    }
  })]

  # The explicit ordering contract this example demonstrates: n8n's
  # ScaledObjects (rendered by this Helm release when its own keda.enabled
  # value is set) must not be created before the KEDA operator exists, and
  # must be destroyed before KEDA is uninstalled.
  depends_on = [module.controllers]
}
