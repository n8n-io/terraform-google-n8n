# ── Cloudflare DNS + cert-manager (Let's Encrypt, DNS-01) ─────────────────────

# A-record: n8n_domain -> the module's LB static IP.
resource "cloudflare_record" "n8n" {
  zone_id = var.cloudflare_zone_id
  name    = var.n8n_domain
  type    = "A"
  content = module.n8n.static_ip
  # Proxied (orange-cloud) works too, but pair it with a Cloudflare Origin CA
  # cert (tls_mode = custom); for Let's Encrypt keep it DNS-only (grey-cloud).
  proxied = false
  ttl     = 1
}

# cert-manager: issues and renews the Let's Encrypt cert.
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true

  set = [{
    name  = "crds.enabled"
    value = "true"
  }]
}

# Cloudflare API token for the DNS-01 solver (cert-manager namespace).
resource "kubernetes_secret" "cloudflare_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = "cert-manager"
  }

  data = {
    api-token = var.cloudflare_api_token
  }

  depends_on = [helm_release.cert_manager]
}

# ClusterIssuer using ACME + Cloudflare DNS-01.
resource "kubectl_manifest" "cluster_issuer" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "letsencrypt-cloudflare" }
    spec = {
      acme = {
        server              = var.acme_server
        email               = var.acme_email
        privateKeySecretRef = { name = "letsencrypt-cloudflare-account-key" }
        solvers = [{
          dns01 = {
            cloudflare = {
              apiTokenSecretRef = {
                name = kubernetes_secret.cloudflare_token.metadata[0].name
                key  = "api-token"
              }
            }
          }
        }]
      }
    }
  })

  depends_on = [helm_release.cert_manager, kubernetes_secret.cloudflare_token]
}

# Certificate in the n8n namespace; cert-manager fills the n8n-tls Secret the
# module's Ingress consumes (tls_mode = secret).
resource "kubectl_manifest" "certificate" {
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "Certificate"
    metadata = {
      name      = "n8n-tls"
      namespace = module.n8n.namespace
    }
    spec = {
      secretName = "n8n-tls"
      dnsNames   = [var.n8n_domain]
      issuerRef = {
        name = "letsencrypt-cloudflare"
        kind = "ClusterIssuer"
      }
    }
  })

  depends_on = [kubectl_manifest.cluster_issuer]
}
