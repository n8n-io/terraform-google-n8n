provider "google" {
  project = var.project_id
  region  = var.gcp_region
}

# google-beta mirrors the google provider configuration; the module uses it
# only to materialize Google-managed service agents (google_project_service_identity)
# before granting CMEK key IAM.
provider "google-beta" {
  project = var.project_id
  region  = var.gcp_region
}

# kubernetes/helm/kubectl authenticate against the GKE cluster the module
# creates, using a short-lived OAuth token from Application Default
# Credentials. On first apply Terraform creates the cluster before any
# kubernetes_*/helm_release/kubectl_manifest resource (module-internal or in
# this example's services.tf/tls.tf) is evaluated.
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
