# Example: modules/controllers direct use

Composes the `modules/controllers` submodule directly, without the
`terraform-google-n8n` root module, against an existing regional GKE cluster.
Demonstrates the explicit dependency ordering a direct caller must provide
between KEDA and their own n8n deployment: see `main.tf`'s
`depends_on = [module.controllers]` on the (illustrative) `helm_release.n8n`.

## Prerequisites

- An existing regional GKE cluster with a compatible node pool.
- `gcloud auth application-default login`.

## Usage

```bash
terraform init
terraform apply \
  -var project_id=my-project \
  -var gke_cluster_name=my-existing-cluster \
  -var n8n_fqdn=n8n.example.com
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | ~> 6.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | ~> 3.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_controllers"></a> [controllers](#module\_controllers) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [helm_release.n8n](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [google_client_config.default](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |
| [google_container_cluster.existing](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/container_cluster) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region of the existing regional GKE cluster. | `string` | `"us-east4"` | no |
| <a name="input_gke_cluster_name"></a> [gke\_cluster\_name](#input\_gke\_cluster\_name) | Name of the existing regional GKE cluster to install KEDA onto. | `string` | n/a | yes |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Hostname the separately managed n8n Helm release is served on. | `string` | n/a | yes |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID that owns the existing GKE cluster. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_keda_installed"></a> [keda\_installed](#output\_keda\_installed) | Whether the controllers submodule installed KEDA. |
| <a name="output_pd_balanced_storage_class_name"></a> [pd\_balanced\_storage\_class\_name](#output\_pd\_balanced\_storage\_class\_name) | Name of the pd-balanced StorageClass the controllers submodule created. |
<!-- END_TF_DOCS -->
