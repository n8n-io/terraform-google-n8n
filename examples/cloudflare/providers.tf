provider "google" {
  project = var.project_id
  region  = var.gcp_region
}

provider "google-beta" {
  project = var.project_id
  region  = var.gcp_region
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# kubernetes/helm/kubectl authenticate to the GKE cluster the module creates,
# using a short-lived OAuth token from Application Default Credentials.
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
