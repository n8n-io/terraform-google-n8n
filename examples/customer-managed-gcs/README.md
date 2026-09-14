# Example: n8n with an existing GCS bucket and BYO HMAC identity

Points n8n's S3-compatible binary storage driver at an existing GCS bucket and
an out-of-band-created HMAC key (`create_gcs_bucket = false`), instead of
letting the module create the bucket and HMAC identity. Every other layer
(VPC, GKE, Cloud SQL, Memorystore, ingress, DNS) is module-managed, same as
[`../small`](../small). See
[`../../docs/customer-managed-infrastructure.md`](../../docs/customer-managed-infrastructure.md)
for the full ownership matrix and every layer's contract.

## Prerequisites

- An existing GCS bucket (`existing_gcs_bucket_name`).
- A pre-existing service account with an out-of-band-created HMAC key
  (`gcs_hmac_service_account_email`, `gcs_hmac_access_id`). The module grants
  this account `objectAdmin` on the bucket; it does not create the account or
  the key, so no org policy override is needed for this example.
- An existing Kubernetes Secret in the n8n namespace holding the HMAC secret
  under key `accessSecret`, created out of band, e.g.:

  ```bash
  kubectl create secret generic external-gcs-hmac-secret \
    -n n8n --from-literal=accessSecret='...'
  ```

  The module never reads this Secret's value; it only passes the reference
  through to the n8n Helm chart.
- APIs: `container`, `sqladmin`, `redis`, `servicenetworking`, `compute`, `iam`.
- `gcloud auth application-default login`.

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # then edit
terraform init
terraform apply
```

Status: preliminary / not scale-validated.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.9 |
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 6.0 |
| <a name="requirement_google-beta"></a> [google-beta](#requirement\_google-beta) | ~> 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | ~> 3.0 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | ~> 1.14 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | ~> 2.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_google"></a> [google](#provider\_google) | ~> 6.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_n8n"></a> [n8n](#module\_n8n) | ../.. | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [google_client_config.default](https://registry.terraform.io/providers/hashicorp/google/latest/docs/data-sources/client_config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_cloud_dns_zone_name"></a> [cloud\_dns\_zone\_name](#input\_cloud\_dns\_zone\_name) | Google Cloud DNS managed-zone name for n8n\_fqdn. Empty means you manage the A-record yourself against the static\_ip output. | `string` | `""` | no |
| <a name="input_existing_gcs_bucket_name"></a> [existing\_gcs\_bucket\_name](#input\_existing\_gcs\_bucket\_name) | Name of the existing GCS bucket used for n8n binary storage. | `string` | n/a | yes |
| <a name="input_friendly_name_prefix"></a> [friendly\_name\_prefix](#input\_friendly\_name\_prefix) | Prefix used to derive the name of every Google Cloud resource the module still creates. | `string` | `"dev"` | no |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region (e.g. us-east4, us-east1, europe-west1). | `string` | `"us-east4"` | no |
| <a name="input_gcs_hmac_access_id"></a> [gcs\_hmac\_access\_id](#input\_gcs\_hmac\_access\_id) | HMAC access ID (S3 access key) for the pre-existing key named by gcs\_hmac\_service\_account\_email. | `string` | n/a | yes |
| <a name="input_gcs_hmac_secret_name"></a> [gcs\_hmac\_secret\_name](#input\_gcs\_hmac\_secret\_name) | Name of an existing Kubernetes Secret (in the n8n namespace) holding the HMAC secret under key "accessSecret". Create this Secret out of band before applying; the module never reads its value. | `string` | n/a | yes |
| <a name="input_gcs_hmac_service_account_email"></a> [gcs\_hmac\_service\_account\_email](#input\_gcs\_hmac\_service\_account\_email) | Email of the pre-existing service account that owns the out-of-band-created HMAC key. The module grants this account objectAdmin on existing\_gcs\_bucket\_name; it does not create the account or the key. | `string` | n/a | yes |
| <a name="input_gke_deletion_protection"></a> [gke\_deletion\_protection](#input\_gke\_deletion\_protection) | Block terraform destroy of the GKE cluster. | `bool` | `true` | no |
| <a name="input_n8n_fqdn"></a> [n8n\_fqdn](#input\_n8n\_fqdn) | Hostname n8n is served on. | `string` | n/a | yes |
| <a name="input_n8n_license_key"></a> [n8n\_license\_key](#input\_n8n\_license\_key) | n8n Enterprise license activation key (multi-main requires Enterprise). | `string` | `""` | no |
| <a name="input_n8n_main_hpa_min_replicas"></a> [n8n\_main\_hpa\_min\_replicas](#input\_n8n\_main\_hpa\_min\_replicas) | Minimum replica count for n8n main pods, passed straight through to the module's own n8n\_main\_hpa\_min\_replicas. Leave null (the default) to use the module's default of 2 (multi-main). Set to 1 to run single-main queue mode instead; see the module's n8n\_main\_hpa\_enabled description for the required license edition and maintenance implications. | `number` | `null` | no |
| <a name="input_postgres_deletion_protection"></a> [postgres\_deletion\_protection](#input\_postgres\_deletion\_protection) | Block terraform destroy of the Cloud SQL instance. | `bool` | `true` | no |
| <a name="input_project_id"></a> [project\_id](#input\_project\_id) | GCP project ID. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_gcs_bucket_name"></a> [gcs\_bucket\_name](#output\_gcs\_bucket\_name) | Effective GCS bucket; should equal var.existing\_gcs\_bucket\_name. |
| <a name="output_kubectl_config_command"></a> [kubectl\_config\_command](#output\_kubectl\_config\_command) | n/a |
| <a name="output_n8n_kube_namespace"></a> [n8n\_kube\_namespace](#output\_n8n\_kube\_namespace) | n/a |
| <a name="output_n8n_url"></a> [n8n\_url](#output\_n8n\_url) | n/a |
| <a name="output_static_ip"></a> [static\_ip](#output\_static\_ip) | LB static IP. Point n8n\_fqdn at this if you are not letting the module manage Cloud DNS. |
<!-- END_TF_DOCS -->
