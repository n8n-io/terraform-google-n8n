# ── TLS and DNS/reachability prerequisites (task 21.3) ─────────────────────────
# create_ingress = false means the module manages no TLS or DNS for this
# example (D9); this file only prepares the caller-supplied TLS material the
# private ingress needs. It does not create either ingress (task 22) or any
# certificate-manager/VPN installation.
#
# Public ingress TLS: a Google-managed certificate, created directly by this
# example (not the module) for the public webhook host, the same mechanism
# examples/small uses for the canonical host. It provisions once
# public_webhook_fqdn's DNS resolves to google_compute_global_address.public
# (network.tf); see README.md for the DNS prerequisite.
resource "kubectl_manifest" "public_managed_certificate" {
  yaml_body = yamlencode({
    apiVersion = "networking.gke.io/v1"
    kind       = "ManagedCertificate"
    metadata = {
      name      = "n8n-split-public-managed-cert"
      namespace = module.n8n.n8n_kube_namespace
    }
    spec = {
      domains = [var.public_webhook_fqdn]
    }
  })

  depends_on = [module.n8n]
}

# Private ingress TLS: GKE's internal Application Load Balancer (the
# "gce-internal" Ingress class) does not provision Google-managed
# certificates; it consumes a Kubernetes TLS Secret. The caller supplies the
# certificate/key (e.g. an internal CA, or a public CA cert if the private
# hostname is still publicly resolvable/nameable); this module never
# generates or self-signs one. Rotate by updating the two *_pem variables and
# re-applying, then restart is not required (the Ingress reads the Secret's
# current contents on each sync), but a manual GKE ingress resync can lag; see
# README.md.
resource "kubernetes_secret_v1" "private_tls" {
  metadata {
    name      = "n8n-split-private-tls"
    namespace = module.n8n.n8n_kube_namespace
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = var.internal_tls_cert_pem
    "tls.key" = var.internal_tls_key_pem
  }

  depends_on = [module.n8n]
}
