provider "google" {
  project = var.project_id
  region  = var.gcp_region
}

data "google_client_config" "default" {}

data "google_container_cluster" "existing" {
  name     = var.gke_cluster_name
  project  = var.project_id
  location = var.gcp_region
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.existing.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.existing.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes = {
    host                   = "https://${data.google_container_cluster.existing.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(data.google_container_cluster.existing.master_auth[0].cluster_ca_certificate)
  }
}
