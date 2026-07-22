provider "google" {
  project = var.project_id
  region  = var.gcp_region
}

provider "google-beta" {
  project = var.project_id
  region  = var.gcp_region
}

# The kubernetes/helm/kubectl providers are configured against the GKE cluster
# the module creates. On the first apply Terraform creates the cluster before
# any kubernetes_*/helm_release/kubectl_manifest resource is evaluated. Auth uses
# a short-lived OAuth token from the google provider's Application Default
# Credentials (no kubeconfig file needed).
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.n8n.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.n8n.cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = "https://${module.n8n.cluster_endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.n8n.cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = "https://${module.n8n.cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.n8n.cluster_ca_certificate)
  load_config_file       = false
}
