provider "google" {
  project = var.project_id
  region  = var.gcp_region
}

# Credentials are read from the GODADDY_API_KEY and GODADDY_API_SECRET
# environment variables, or set here via variables. Create an API key at
# https://developer.godaddy.com/keys.
provider "godaddy-dns" {
  api_key    = var.godaddy_api_key
  api_secret = var.godaddy_api_secret
}

# kubernetes/helm/kubectl authenticate against the GKE cluster the module
# creates, using a short-lived OAuth token from Application Default Credentials.
# On first apply Terraform creates the cluster before any kubernetes_* /
# helm_release / kubectl_manifest resource is evaluated.
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
