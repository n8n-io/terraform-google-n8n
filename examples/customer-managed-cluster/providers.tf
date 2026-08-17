provider "google" {
  project = var.project_id
  region  = var.gcp_region
}

# The kubernetes/helm/kubectl providers are configured against the effective
# GKE cluster the module resolves - here, the existing cluster named by
# existing_gke_cluster_name (module.n8n.gke_cluster_endpoint/_ca_certificate
# resolve to the same data lookup the module performs internally). Auth uses a
# short-lived OAuth token from the google provider's Application Default
# Credentials (no kubeconfig file needed).
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.n8n.gke_cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.n8n.gke_cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = "https://${module.n8n.gke_cluster_endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(module.n8n.gke_cluster_ca_certificate)
  }
}

provider "kubectl" {
  host                   = "https://${module.n8n.gke_cluster_endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(module.n8n.gke_cluster_ca_certificate)
  load_config_file       = false
}
